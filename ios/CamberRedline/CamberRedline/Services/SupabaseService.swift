import Foundation
import Supabase

// MARK: - SupabaseService

@MainActor
final class SupabaseService {
    static let shared = SupabaseService()

    // Retained for Realtime subscriptions (claim_grades, interactions channels).
    let client: SupabaseClient

    private let edgeFunctionBaseURL = URL(
        string: "https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/redline-thread"
    )!
    private let reviewResolveURL = URL(
        string: "https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/review-resolve"
    )!

    private let anonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJqaGR3aWRkZHRmZXRid3FvbG9mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjUxMTYwNDQsImV4cCI6MjA4MDY5MjA0NH0.m0BArfDxAMQrX2-50_IgircX_SwWLe5VccxewGmuWio"
    private let reviewResolveAuthEmail = "redline_ios_dev3_resolver@example.com"
    private let reviewResolveAuthPassword = "RedlineDev3!2026"

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: "https://rjhdwidddtfetbwqolof.supabase.co")!,
            supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJqaGR3aWRkZHRmZXRid3FvbG9mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjUxMTYwNDQsImV4cCI6MjA4MDY5MjA0NH0.m0BArfDxAMQrX2-50_IgircX_SwWLe5VccxewGmuWio"
        )
    }

    // MARK: - Fetch Contacts (edge function: GET ?action=contacts)

    func fetchContactsList() async throws -> [Contact] {
        var components = URLComponents(url: edgeFunctionBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "contacts"),
            URLQueryItem(name: "_ts", value: String(Int(Date().timeIntervalSince1970))),
        ]

        guard let url = components.url else {
            throw ServiceError.apiError("Failed to construct contacts URL")
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)

        let decoded = try JSONDecoder().decode(ContactsResponse.self, from: data)
        guard decoded.ok else {
            throw ServiceError.apiError("Contacts endpoint returned ok=false")
        }
        return decoded.contacts
    }

    func fetchContacts() async throws -> [Contact] {
        try await fetchContactsList()
    }

    // MARK: - Fetch Thread (edge function: GET ?contact_id=X&limit=Y&offset=Z)

    func fetchThread(contactId: UUID, limit: Int = 50, offset: Int = 0) async throws -> ThreadResponse {
        var components = URLComponents(url: edgeFunctionBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "contact_id", value: contactId.uuidString.lowercased()),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "_ts", value: String(Int(Date().timeIntervalSince1970))),
        ]

        guard let url = components.url else {
            throw ServiceError.apiError("Failed to construct thread URL")
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)

        let decoded = try JSONDecoder().decode(ThreadResponse.self, from: data)
        guard decoded.ok else {
            throw ServiceError.apiError("Thread endpoint returned ok=false")
        }
        return decoded
    }

    // MARK: - Grade Claim (edge function: POST { claim_id, grade, graded_by })

    func gradeClaimViaAPI(
        claimId: UUID,
        grade: String,
        correctionText: String?,
        gradedBy: String
    ) async throws {
        let body = NewGrade(
            claimId: claimId,
            grade: grade,
            correctionText: correctionText,
            gradedBy: gradedBy
        )

        var request = URLRequest(url: edgeFunctionBaseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = json["ok"] as? Bool, !ok
        {
            let message = json["error"] as? String ?? "Unknown error"
            throw ServiceError.apiError(message)
        }
    }

    // MARK: - Reset Grading Clock (edge function: GET ?action=reset_clock)

    func resetGradingClock() async throws {
        var components = URLComponents(url: edgeFunctionBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "reset_clock"),
            URLQueryItem(name: "_ts", value: String(Int(Date().timeIntervalSince1970))),
        ]

        guard let url = components.url else {
            throw ServiceError.apiError("Failed to construct reset_clock URL")
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = json["ok"] as? Bool, !ok
        {
            let message = json["error"] as? String ?? "Unknown error"
            throw ServiceError.apiError(message)
        }
    }

    // MARK: - Resolve Review Queue Item (edge function: review-resolve)

    func resolveReviewQueueItem(
        reviewQueueId: String,
        chosenProjectId: String,
        notes: String? = nil,
        source: String = "redline"
    ) async throws -> ReviewResolveResponse {
        let accessToken = try await reviewResolveAccessToken()

        var request = URLRequest(url: reviewResolveURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(
            ReviewResolveRequest(
                reviewQueueId: reviewQueueId,
                chosenProjectId: chosenProjectId,
                notes: notes,
                source: source
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        let payload = try? JSONDecoder().decode(ReviewResolveResponse.self, from: data)
        let errorMessage = payload?.error
            ?? payload?.detail
            ?? String(data: data, encoding: .utf8)
            ?? "Review resolve failed"

        guard (200...299).contains(http.statusCode) else {
            throw ServiceError.apiError(errorMessage)
        }

        guard payload?.ok == true else {
            throw ServiceError.apiError(errorMessage)
        }

        return payload!
    }

    // MARK: - Helpers

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ServiceError.httpError(statusCode: http.statusCode)
        }
    }

    private func reviewResolveAccessToken() async throws -> String {
        if let currentSession = client.auth.currentSession, !currentSession.isExpired {
            return currentSession.accessToken
        }

        if let refreshedSession = try? await client.auth.session {
            return refreshedSession.accessToken
        }

        do {
            let session = try await client.auth.signIn(
                email: reviewResolveAuthEmail,
                password: reviewResolveAuthPassword
            )
            return session.accessToken
        } catch {
            throw ServiceError.apiError(
                "Review resolve authentication failed: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Response Types

/// Wrapper for GET ?action=contacts → { ok, contacts: [...] }
struct ContactsResponse: Decodable {
    let ok: Bool
    let contacts: [Contact]
}

struct ThreadContactInfo: Decodable {
    let id: UUID
    let name: String
    let phone: String
}

struct ThreadPagination: Decodable {
    let total: Int
    let limit: Int
    let offset: Int
}

struct ThreadResponse: Decodable {
    let ok: Bool
    let contact: ThreadContactInfo
    let thread: [RawThreadItem]
    let pagination: ThreadPagination
}

struct ReviewResolveResponse: Decodable {
    let ok: Bool?
    let error: String?
    let detail: String?
    let reviewQueueId: String?
    let chosenProjectId: String?
    let wasAlreadyResolved: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case detail
        case reviewQueueId = "review_queue_id"
        case chosenProjectId = "chosen_project_id"
        case wasAlreadyResolved = "was_already_resolved"
    }
}

private struct ReviewResolveRequest: Encodable {
    let reviewQueueId: String
    let chosenProjectId: String
    let notes: String?
    let source: String

    enum CodingKeys: String, CodingKey {
        case reviewQueueId = "review_queue_id"
        case chosenProjectId = "chosen_project_id"
        case notes
        case source
    }
}

// MARK: - RawThreadItem (polymorphic decoding)

/// Decodes a polymorphic thread item from the v2 edge function response.
/// Delegates to `CallEntry` / `SMSEntry` Codable conformance so field mappings
/// stay in one place (CodingKeys on each model).
struct RawThreadItem: Decodable {
    let type: String
    let callEntry: CallEntry?
    let smsEntry: SMSEntry?

    private enum TypeKey: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: TypeKey.self)
        type = try typeContainer.decode(String.self, forKey: .type)

        switch type {
        case "call":
            callEntry = try CallEntry(from: decoder)
            smsEntry = nil
        case "sms":
            callEntry = nil
            smsEntry = try SMSEntry(from: decoder)
        default:
            callEntry = nil
            smsEntry = nil
        }
    }

    func toThreadItem() -> ThreadItem? {
        switch type {
        case "call":
            guard let entry = callEntry else { return nil }
            return .call(entry)
        case "sms":
            guard let entry = smsEntry else { return nil }
            return .sms(entry)
        default:
            return nil
        }
    }
}

// MARK: - ServiceError

enum ServiceError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server."
        case .httpError(let code):
            return "HTTP error \(code)."
        case .apiError(let message):
            return message
        }
    }
}
