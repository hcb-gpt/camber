import Foundation

// MARK: - BootstrapService

@MainActor
final class BootstrapService {
    static let shared = BootstrapService()

    private let baseURL = URL(
        string: "https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/bootstrap-review"
    )!

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var cachedReviewProjects: [ReviewProject] = []
    private var cachedReviewProjectsAt: Date?
    private let reviewProjectsCacheTTL: TimeInterval = 5 * 60

    private init() {
        session = URLSession.shared
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    // MARK: - Fetch Queue

    func fetchQueue(limit: Int = 30) async throws -> ReviewQueueResponse {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "queue"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]

        guard let url = components.url else {
            throw BootstrapServiceError.invalidURL
        }

        let (data, response) = try await session.data(from: url)
        try validateHTTPResponse(response)

        let decoded = try decoder.decode(ReviewQueueResponse.self, from: data)
        guard decoded.ok else {
            throw BootstrapServiceError.apiError("queue endpoint returned ok=false")
        }
        return decoded
    }

    // MARK: - Review Projects Cache

    func fetchReviewProjects(forceRefresh: Bool = false) async throws -> [ReviewProject] {
        if !forceRefresh,
           !cachedReviewProjects.isEmpty,
           let cachedAt = cachedReviewProjectsAt,
           Date().timeIntervalSince(cachedAt) < reviewProjectsCacheTTL
        {
            return cachedReviewProjects
        }

        let response = try await fetchQueue(limit: 1)
        cachedReviewProjects = response.projects
        cachedReviewProjectsAt = Date()
        return response.projects
    }

    func snapshotCachedReviewProjects() -> [ReviewProject] {
        cachedReviewProjects
    }

    func reviewProjectsCacheAge() -> TimeInterval? {
        guard let cachedAt = cachedReviewProjectsAt else { return nil }
        return Date().timeIntervalSince(cachedAt)
    }

    // MARK: - Resolve

    func resolve(
        queueId: String,
        projectId: String,
        userId: String = "ios-user"
    ) async throws -> ResolveResponse {
        let body = ResolveRequest(reviewQueueId: queueId, projectId: projectId, userId: userId)
        let data = try await post(action: "resolve", body: body)
        let response = try decoder.decode(ResolveResponse.self, from: data)
        guard response.ok else {
            throw BootstrapServiceError.apiError(
                response.error ?? "Resolve endpoint returned ok=false"
            )
        }
        return response
    }

    // MARK: - Dismiss

    func dismiss(queueId: String, userId: String = "ios-user") async throws {
        let body = DismissRequest(reviewQueueId: queueId, userId: userId)
        let data = try await post(action: "dismiss", body: body)
        try decodeOkResponse(data, action: "dismiss")
    }

    // MARK: - Undo

    func undo(queueId: String) async throws {
        let body = UndoRequest(reviewQueueId: queueId)
        let data = try await post(action: "undo", body: body)
        try decodeOkResponse(data, action: "undo")
    }

    // MARK: - Assistant Context

    private let assistantContextURL = URL(
        string: "https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/assistant-context"
    )!

    func fetchAssistantContext(projectId: String? = nil) async throws -> AssistantContextPacket {
        var components = URLComponents(url: assistantContextURL, resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []
        if let projectId {
            queryItems.append(URLQueryItem(name: "project_id", value: projectId))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw BootstrapServiceError.invalidURL
        }

        let (data, response) = try await session.data(from: url)
        try validateHTTPResponse(response)
        let packet = try decoder.decode(AssistantContextPacket.self, from: data)
        let transportRequestId = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "x-request-id")
        logAssistantContextSmoke(packet: packet, transportRequestId: transportRequestId)
        return packet
    }

    private func logAssistantContextSmoke(
        packet: AssistantContextPacket,
        transportRequestId: String?
    ) {
        let bodyRequestId = packet.requestId ?? "none"
        let responseRequestId = transportRequestId ?? "none"
        let contractVersion = packet.contractVersion ?? packet.metricContract?.version ?? "none"
        let functionVersion = packet.functionVersion ?? "none"
        print(
            "SMOKE assistant-context sb_request_id=\(responseRequestId) body_request_id=\(bodyRequestId) contract_version=\(contractVersion) function_version=\(functionVersion)"
        )
    }

    // MARK: - Assistant Chat

    private let assistantChatURL = URL(
        string: "https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/redline-assistant"
    )!

    func streamAssistantChat(
        message: String,
        contactId: String? = nil,
        projectId: String? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: assistantChatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "message": message,
            "contact_id": contactId as Any,
            "project_id": projectId as Any
        ].compactMapValues { $0 }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        try validateHTTPResponse(response)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6))
                            if jsonStr == "[DONE]" {
                                continuation.finish()
                                return
                            }
                            if let data = jsonStr.data(using: .utf8),
                               let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let choices = chunk["choices"] as? [[String: Any]],
                               let delta = choices.first?["delta"] as? [String: Any],
                               let content = delta["content"] as? String {
                                continuation.yield(content)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers

    private func post<T: Encodable>(action: String, body: T) async throws -> Data {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: action)]

        guard let url = components.url else {
            throw BootstrapServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)
        return data
    }

    private func decodeOkResponse(_ data: Data, action: String) throws {
        guard let parsed = try? decoder.decode(BootstrapActionResponse.self, from: data) else {
            return
        }
        guard parsed.ok else {
            throw BootstrapServiceError.apiError(
                parsed.error ?? "Unknown error from \(action)"
            )
        }
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BootstrapServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw BootstrapServiceError.httpError(statusCode: http.statusCode)
        }
    }
}

struct ResolveResponse: Decodable {
    let ok: Bool
    let reviewQueueId: String?
    let chosenProjectId: String?
    let wasAlreadyResolved: Bool?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case reviewQueueId = "review_queue_id"
        case chosenProjectId = "chosen_project_id"
        case wasAlreadyResolved = "was_already_resolved"
        case error
    }
}

private struct BootstrapActionResponse: Decodable {
    let ok: Bool
    let error: String?
}

// MARK: - Request Bodies

private struct ResolveRequest: Encodable {
    let reviewQueueId: String
    let projectId: String
    let userId: String

    enum CodingKeys: String, CodingKey {
        case reviewQueueId = "review_queue_id"
        case projectId = "project_id"
        case userId = "user_id"
    }
}

private struct DismissRequest: Encodable {
    let reviewQueueId: String
    let userId: String

    enum CodingKeys: String, CodingKey {
        case reviewQueueId = "review_queue_id"
        case userId = "user_id"
    }
}

private struct UndoRequest: Encodable {
    let reviewQueueId: String

    enum CodingKeys: String, CodingKey {
        case reviewQueueId = "review_queue_id"
    }
}

// MARK: - BootstrapServiceError

enum BootstrapServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to construct request URL."
        case .invalidResponse:
            return "Invalid response from server."
        case .httpError(let code):
            return "HTTP error \(code)."
        case .apiError(let message):
            return message
        }
    }
}
