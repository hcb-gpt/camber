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
        notes: String? = nil,
        userId: String = "ios-user"
    ) async throws -> ResolveResponse {
        let body = ResolveRequest(
            reviewQueueId: queueId,
            projectId: projectId,
            notes: notes,
            userId: userId
        )
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

    func dismiss(
        queueId: String,
        reason: String? = nil,
        notes: String? = nil,
        userId: String = "ios-user"
    ) async throws {
        let body = DismissRequest(
            reviewQueueId: queueId,
            reason: reason,
            notes: notes,
            userId: userId
        )
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
        do {
            return try decoder.decode(AssistantContextPacket.self, from: data)
        } catch let error as DecodingError {
            let path: String = switch error {
            case .typeMismatch(_, let context),
                 .valueNotFound(_, let context),
                 .keyNotFound(_, let context),
                 .dataCorrupted(let context):
                context.codingPath.map(\.stringValue).joined(separator: ".")
            @unknown default:
                "unknown"
            }
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8>"
            print("[AssistantContextDecode] path=\(path) error=\(error)")
            print("[AssistantContextDecode] payload_preview=\(preview)")
            throw BootstrapServiceError.apiError("Assistant context decode failure at path: \(path)")
        }
    }

    // MARK: - Assistant Chat

    private let assistantChatURL = URL(
        string: "https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/redline-assistant"
    )!

    private let assistantFeedbackURL = URL(
        string: "https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/assistant-feedback"
    )!

    func streamAssistantChat(
        message: String,
        contactId: String? = nil,
        projectId: String? = nil,
        history: [AssistantChatHistoryMessage] = []
    ) async throws -> AssistantChatSession {
        var request = URLRequest(url: assistantChatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "message": message,
            "contact_id": contactId as Any,
            "project_id": projectId as Any,
            "history": history.map { ["role": $0.role, "content": $0.content] }
        ].compactMapValues { $0 }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let payloadString = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "{}"

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BootstrapServiceError.invalidResponse
        }

        let requestId = http.value(forHTTPHeaderField: "x-request-id")
        let provider = http.value(forHTTPHeaderField: "x-assistant-provider")
        let model = http.value(forHTTPHeaderField: "x-assistant-model")
        let providerWarning = http.value(forHTTPHeaderField: "x-assistant-provider-warning")

        if !(200...299).contains(http.statusCode) {
            var errorBody = ""
            do {
                for try await line in bytes.lines {
                    errorBody += line + "\n"
                }
            } catch {
                throw AssistantChatHTTPError(
                    statusCode: http.statusCode,
                    requestId: requestId,
                    body: "Unable to read error body: \(error.localizedDescription)"
                )
            }
            throw AssistantChatHTTPError(
                statusCode: http.statusCode,
                requestId: requestId,
                body: errorBody.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let stream = AsyncThrowingStream<String, Error> { continuation in
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

        return AssistantChatSession(
            stream: stream,
            debug: AssistantChatDebugInfo(
                endpointURL: assistantChatURL.absoluteString,
                payloadJSON: payloadString,
                statusCode: http.statusCode,
                requestId: requestId,
                provider: provider,
                model: model,
                providerWarning: providerWarning
            )
        )
    }

    func submitAssistantFeedback(_ payload: AssistantFeedbackPayload) async throws -> AssistantFeedbackResponse {
        var request = URLRequest(url: assistantFeedbackURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        let decoded = try decoder.decode(AssistantFeedbackResponse.self, from: data)
        guard decoded.ok else {
            throw BootstrapServiceError.apiError(decoded.error ?? "assistant feedback returned ok=false")
        }
        return decoded
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
    let notes: String?
    let userId: String

    enum CodingKeys: String, CodingKey {
        case reviewQueueId = "review_queue_id"
        case projectId = "project_id"
        case notes
        case userId = "user_id"
    }
}

private struct DismissRequest: Encodable {
    let reviewQueueId: String
    let reason: String?
    let notes: String?
    let userId: String

    enum CodingKeys: String, CodingKey {
        case reviewQueueId = "review_queue_id"
        case reason
        case notes
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

struct AssistantChatHistoryMessage: Encodable {
    let role: String
    let content: String
}

struct AssistantChatDebugInfo {
    let endpointURL: String
    let payloadJSON: String
    let statusCode: Int
    let requestId: String?
    let provider: String?
    let model: String?
    let providerWarning: String?
}

struct AssistantChatSession {
    let stream: AsyncThrowingStream<String, Error>
    let debug: AssistantChatDebugInfo
}

struct AssistantFeedbackPayload: Encodable {
    let messageId: String
    let messageRole: String
    let feedback: String
    let note: String?
    let requestId: String?
    let contactId: String?
    let projectId: String?
    let prompt: String?
    let responseExcerpt: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case messageRole = "message_role"
        case feedback
        case note
        case requestId = "request_id"
        case contactId = "contact_id"
        case projectId = "project_id"
        case prompt
        case responseExcerpt = "response_excerpt"
    }
}

struct AssistantFeedbackResponse: Decodable {
    let ok: Bool
    let feedbackId: String?
    let requestId: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case feedbackId = "feedback_id"
        case requestId = "request_id"
        case error
    }
}

struct AssistantChatHTTPError: LocalizedError {
    let statusCode: Int
    let requestId: String?
    let body: String

    var errorDescription: String? {
        if let requestId, !requestId.isEmpty {
            return "HTTP \(statusCode) (request_id: \(requestId)). \(body)"
        }
        return "HTTP \(statusCode). \(body)"
    }
}
