import Foundation
import Supabase

// MARK: - SupabaseService

final class SupabaseService {
    static let shared = SupabaseService()

    let client: SupabaseClient

    private let edgeFunctionBaseURL = URL(
        string: "https://rjhdwidddtfetbwqolof.supabase.co/functions/v1/redline-thread"
    )!

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: "https://rjhdwidddtfetbwqolof.supabase.co")!,
            supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJqaGR3aWRkZHRmZXRid3FvbG9mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjUxMTYwNDQsImV4cCI6MjA4MDY5MjA0NH0.m0BArfDxAMQrX2-50_IgircX_SwWLe5VccxewGmuWio"
        )
    }

    // MARK: - Fetch Contacts

    func fetchContactsList() async throws -> [Contact] {
        try await client
            .from("redline_contacts")
            .select()
            .order("last_activity", ascending: false, nullsFirst: false)
            .execute()
            .value
    }

    func fetchContacts() async throws -> [Contact] {
        try await fetchContactsList()
    }

    // MARK: - Fetch Thread

    func fetchThread(contactId: UUID, limit: Int = 100) async throws -> ThreadResponse {
        var components = URLComponents(url: edgeFunctionBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "contact_id", value: contactId.uuidString.lowercased()),
            URLQueryItem(name: "limit", value: String(limit)),
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try validateHTTPResponse(response)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ThreadResponse.self, from: data)
        guard decoded.ok else {
            throw ServiceError.apiError("Thread endpoint returned ok=false")
        }
        return decoded
    }

    // MARK: - Grade Claim

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
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)

        // Verify the response indicates success
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = json["ok"] as? Bool, !ok
        {
            let message = json["error"] as? String ?? "Unknown error"
            throw ServiceError.apiError(message)
        }
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
}

// MARK: - Response Types

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

// MARK: - RawThreadItem (polymorphic decoding)

struct RawThreadItem: Decodable {
    let type: String
    let callEntry: CallEntry?
    let smsEntry: SMSEntry?

    enum CodingKeys: String, CodingKey {
        case type
        case eventAt = "event_at"
        case direction
        case summary
        case spans
        case interactionId = "interaction_id"
        case content
        case smsId = "sms_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)

        switch type {
        case "call":
            let interactionId = try container.decodeIfPresent(String.self, forKey: .interactionId) ?? ""
            let eventAt = try container.decode(String.self, forKey: .eventAt)
            let direction = try container.decodeIfPresent(String.self, forKey: .direction)
            let summary = try container.decodeIfPresent(String.self, forKey: .summary)
            let spans = try container.decodeIfPresent([SpanEntry].self, forKey: .spans) ?? []
            callEntry = CallEntry(
                interactionId: interactionId,
                eventAt: eventAt,
                direction: direction,
                summary: summary,
                spans: spans
            )
            smsEntry = nil

        case "sms":
            let smsId = try container.decodeIfPresent(UUID.self, forKey: .smsId) ?? UUID()
            let eventAt = try container.decode(String.self, forKey: .eventAt)
            let direction = try container.decodeIfPresent(String.self, forKey: .direction)
            let content = try container.decodeIfPresent(String.self, forKey: .content)
            smsEntry = SMSEntry(
                smsId: smsId,
                eventAt: eventAt,
                direction: direction,
                content: content
            )
            callEntry = nil

        default:
            callEntry = nil
            smsEntry = nil
        }
    }

    /// Convert to the strongly-typed ThreadItem enum.
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
