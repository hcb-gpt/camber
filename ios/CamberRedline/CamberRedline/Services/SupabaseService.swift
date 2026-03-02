import Foundation
import Supabase

// MARK: - SupabaseService

@MainActor
final class SupabaseService {
    static let shared = SupabaseService()

    private enum Config {
        static let supabaseURLKey = "SUPABASE_URL"
        static let supabaseAnonKeyKey = "SUPABASE_ANON_KEY"
        static let fallbackSupabaseURL = URL(string: "https://example.invalid")!
        static let fallbackAnonKey = "invalid-anon-key"
    }

    private struct ThreadCacheKey: Hashable {
        let contactId: UUID
        let limit: Int
        let offset: Int
    }

    private struct ThreadCacheEntry {
        let response: ThreadResponse
        let fetchedAt: Date
    }

    // Retained for Realtime subscriptions (claim_grades, interactions channels).
    let client: SupabaseClient

    private let edgeFunctionBaseURL: URL
    private let reviewResolveURL: URL

    private let anonKey: String
    private let configurationErrorMessage: String?
    private let threadCacheTTL: TimeInterval = 30
    private var threadCache: [ThreadCacheKey: ThreadCacheEntry] = [:]

    private init() {
        let env = ProcessInfo.processInfo.environment
        let supabaseUrlString = (env[Config.supabaseURLKey]
            ?? (Bundle.main.object(forInfoDictionaryKey: Config.supabaseURLKey) as? String)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let anonKey = (env[Config.supabaseAnonKeyKey]
            ?? (Bundle.main.object(forInfoDictionaryKey: Config.supabaseAnonKeyKey) as? String)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let supabaseURL = URL(string: supabaseUrlString) ?? Config.fallbackSupabaseURL
        let resolvedAnonKey = anonKey.isEmpty ? Config.fallbackAnonKey : anonKey

        let configurationErrorMessage = (supabaseURL == Config.fallbackSupabaseURL || anonKey.isEmpty)
            ? "Missing/invalid \(Config.supabaseURLKey) / \(Config.supabaseAnonKeyKey); check Info.plist or env vars."
            : nil
        #if DEBUG
        if let configurationErrorMessage {
            print("[SupabaseService] \(configurationErrorMessage)")
        }
        #endif

        self.anonKey = resolvedAnonKey
        self.configurationErrorMessage = configurationErrorMessage
        edgeFunctionBaseURL = supabaseURL.appendingPathComponent("functions/v1/redline-thread")
        reviewResolveURL = supabaseURL.appendingPathComponent("functions/v1/review-resolve")

        client = SupabaseClient(
            supabaseURL: supabaseURL,
            supabaseKey: resolvedAnonKey
        )
    }

    private func requireValidConfiguration() throws {
        if let configurationErrorMessage {
            throw ServiceError.misconfigured(configurationErrorMessage)
        }
    }

    // MARK: - Fetch Contacts (edge function: GET ?action=contacts)

    func fetchContactsList() async throws -> [Contact] {
        try requireValidConfiguration()

        var components = URLComponents(url: edgeFunctionBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "contacts"),
            URLQueryItem(name: "refresh", value: "1"),
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
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        try validateHTTPResponse(response)

        let decoded: ContactsResponse
        do {
            decoded = try JSONDecoder().decode(ContactsResponse.self, from: data)
        } catch let decodingError as DecodingError {
            #if DEBUG
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            print("[ContactsDecode] DecodingError: \(decodingError)")
            if case .typeMismatch(let type, let ctx) = decodingError {
                print("[ContactsDecode] typeMismatch: expected \(type), codingPath: \(ctx.codingPath.map(\.stringValue))")
            } else if case .keyNotFound(let key, let ctx) = decodingError {
                print("[ContactsDecode] keyNotFound: \(key.stringValue), codingPath: \(ctx.codingPath.map(\.stringValue))")
            } else if case .valueNotFound(let type, let ctx) = decodingError {
                print("[ContactsDecode] valueNotFound: \(type), codingPath: \(ctx.codingPath.map(\.stringValue))")
            }
            print("[ContactsDecode] HTTP \(httpStatus), response preview: \(preview)")
            #else
            print("[ContactsDecode] HTTP \(httpStatus)")
            #endif
            throw decodingError
        }
        guard decoded.ok else {
            throw ServiceError.apiError("Contacts endpoint returned ok=false")
        }
        return decoded.contacts
    }

    func fetchContacts() async throws -> [Contact] {
        try await fetchContactsList()
    }

    // MARK: - Fetch Thread (edge function: GET ?contact_id=X&limit=Y&offset=Z)

    func fetchThread(
        contactId: UUID,
        limit: Int = 50,
        offset: Int = 0,
        preferCache: Bool = true,
        forceRefresh: Bool = false
    ) async throws -> ThreadResponse {
        try requireValidConfiguration()

        let cacheKey = ThreadCacheKey(contactId: contactId, limit: limit, offset: offset)
        if preferCache, !forceRefresh, let cached = cachedThreadResponse(for: cacheKey) {
            return cached
        }

        var components = URLComponents(url: edgeFunctionBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "contact_id", value: contactId.uuidString.lowercased()),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "refresh", value: "1"),
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
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        try validateHTTPResponse(response)

        let decoded: ThreadResponse
        do {
            decoded = try JSONDecoder().decode(ThreadResponse.self, from: data)
        } catch let decodingError as DecodingError {
            #if DEBUG
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            print("[ThreadDecode] DecodingError: \(decodingError)")
            if case .typeMismatch(let type, let ctx) = decodingError {
                print("[ThreadDecode] typeMismatch: expected \(type), codingPath: \(ctx.codingPath.map(\.stringValue))")
            } else if case .keyNotFound(let key, let ctx) = decodingError {
                print("[ThreadDecode] keyNotFound: \(key.stringValue), codingPath: \(ctx.codingPath.map(\.stringValue))")
            } else if case .valueNotFound(let type, let ctx) = decodingError {
                print("[ThreadDecode] valueNotFound: \(type), codingPath: \(ctx.codingPath.map(\.stringValue))")
            }
            print("[ThreadDecode] HTTP \(httpStatus), response preview: \(preview)")
            #else
            print("[ThreadDecode] HTTP \(httpStatus)")
            #endif
            throw decodingError
        }
        guard decoded.ok else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let errorCode = json["error_code"] as? String
                let errorMsg = json["error"] as? String
                let detail = [errorCode, errorMsg].compactMap { $0 }.joined(separator: ": ")
                if !detail.isEmpty {
                    throw ServiceError.apiError("Thread endpoint: \(detail)")
                }
            }
            throw ServiceError.apiError("Thread endpoint returned ok=false")
        }
        if decoded.droppedCount > 0 {
            print("[ThreadDecode] Lossy decode dropped \(decoded.droppedCount) malformed thread items")
        }
        threadCache[cacheKey] = ThreadCacheEntry(response: decoded, fetchedAt: Date())
        return decoded
    }

    // MARK: - Truth Graph (edge function: GET ?action=truth_graph&interaction_id=X)

    func fetchTruthGraph(interactionId: String) async throws -> TruthGraphResponse {
        try requireValidConfiguration()

        var components = URLComponents(url: edgeFunctionBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "truth_graph"),
            URLQueryItem(name: "interaction_id", value: interactionId),
            URLQueryItem(name: "refresh", value: "1"),
            URLQueryItem(name: "_ts", value: String(Int(Date().timeIntervalSince1970))),
        ]

        guard let url = components.url else {
            throw ServiceError.apiError("Failed to construct truth_graph URL")
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)

        let decoded = try JSONDecoder().decode(TruthGraphResponse.self, from: data)
        guard decoded.ok else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let errorCode = json["error_code"] as? String
                let errorMsg = json["error"] as? String
                let detail = [errorCode, errorMsg].compactMap { $0 }.joined(separator: ": ")
                if !detail.isEmpty {
                    throw ServiceError.apiError("Truth Graph endpoint: \(detail)")
                }
            }
            throw ServiceError.apiError("Truth Graph endpoint returned ok=false")
        }
        return decoded
    }

    func prefetchThread(contactId: UUID, limit: Int = 50, offset: Int = 0) async {
        guard configurationErrorMessage == nil else { return }

        _ = try? await fetchThread(
            contactId: contactId,
            limit: limit,
            offset: offset,
            preferCache: true,
            forceRefresh: false
        )
    }

    func invalidateThreadCache(for contactId: UUID? = nil) {
        guard let contactId else {
            threadCache.removeAll()
            return
        }
        threadCache = threadCache.filter { $0.key.contactId != contactId }
    }

    // MARK: - Grade Claim (edge function: POST { claim_id, grade, graded_by })

    func gradeClaimViaAPI(
        claimId: UUID,
        grade: String,
        correctionText: String?,
        gradedBy: String
    ) async throws {
        try requireValidConfiguration()

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
        try requireValidConfiguration()

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
        try requireValidConfiguration()

        let accessToken = try await reviewResolveAccessToken()
        return try await Self.performReviewResolveRequest(
            url: reviewResolveURL,
            anonKey: anonKey,
            accessToken: accessToken,
            payload: ReviewResolveRequest(
                reviewQueueId: reviewQueueId,
                chosenProjectId: chosenProjectId,
                notes: notes,
                source: source
            )
        )
    }

    func resolveReviewQueueItemsBatch(
        reviewQueueIds: [String],
        chosenProjectId: String,
        notes: String? = nil,
        source: String = "redline"
    ) async throws -> [ReviewResolveResponse] {
        try requireValidConfiguration()

        var seen = Set<String>()
        let uniqueQueueIds = reviewQueueIds.filter { seen.insert($0).inserted }
        guard !uniqueQueueIds.isEmpty else { return [] }

        let accessToken = try await reviewResolveAccessToken()
        let requestURL = reviewResolveURL
        let apiKey = anonKey
        var responsesById: [String: ReviewResolveResponse] = [:]

        try await withThrowingTaskGroup(of: (String, ReviewResolveResponse).self) { group in
            for queueId in uniqueQueueIds {
                group.addTask {
                    let response = try await Self.performReviewResolveRequest(
                        url: requestURL,
                        anonKey: apiKey,
                        accessToken: accessToken,
                        payload: ReviewResolveRequest(
                            reviewQueueId: queueId,
                            chosenProjectId: chosenProjectId,
                            notes: notes,
                            source: source
                        )
                    )
                    return (queueId, response)
                }
            }

            for try await (queueId, response) in group {
                responsesById[queueId] = response
            }
        }

        return uniqueQueueIds.compactMap { responsesById[$0] }
    }

    // MARK: - Pipeline Heartbeat (direct Supabase query)

    func fetchPipelineHeartbeat() async throws -> [PipelineHeartbeat] {
        try requireValidConfiguration()

        let rows: [PipelineHeartbeat] = try await client
            .from("pipeline_heartbeat")
            .select()
            .execute()
            .value
        return rows
    }

    // MARK: - Helpers

    private func cachedThreadResponse(for key: ThreadCacheKey) -> ThreadResponse? {
        guard let cached = threadCache[key] else { return nil }
        guard Date().timeIntervalSince(cached.fetchedAt) < threadCacheTTL else {
            threadCache.removeValue(forKey: key)
            return nil
        }
        return cached.response
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ServiceError.httpError(statusCode: http.statusCode)
        }
    }

    private nonisolated static func performReviewResolveRequest(
        url: URL,
        anonKey: String,
        accessToken: String,
        payload: ReviewResolveRequest
    ) async throws -> ReviewResolveResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        let decoded = try? JSONDecoder().decode(ReviewResolveResponse.self, from: data)
        let errorMessage = decoded?.error
            ?? decoded?.detail
            ?? String(data: data, encoding: .utf8)
            ?? "Review resolve failed"

        guard (200...299).contains(http.statusCode) else {
            throw ServiceError.apiError(errorMessage)
        }

        guard decoded?.ok == true else {
            throw ServiceError.apiError(errorMessage)
        }

        return decoded!
    }

    private func reviewResolveAccessToken() async throws -> String {
        if let currentSession = client.auth.currentSession, !currentSession.isExpired {
            return currentSession.accessToken
        }

        if let refreshedSession = try? await client.auth.session, !refreshedSession.isExpired {
            return refreshedSession.accessToken
        }

        throw ServiceError.apiError(
            "Review resolve requires an authenticated user session. Sign in before resolving."
        )
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
    let droppedCount: Int

    private enum CodingKeys: String, CodingKey {
        case ok, contact, thread, pagination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        contact = try container.decode(ThreadContactInfo.self, forKey: .contact)
        pagination = try container.decode(ThreadPagination.self, forKey: .pagination)

        // Lossy array decode: skip individual malformed thread items instead of
        // failing the entire response.
        var itemsContainer = try container.nestedUnkeyedContainer(forKey: .thread)
        var items: [RawThreadItem] = []
        var dropped = 0
        while !itemsContainer.isAtEnd {
            if let item = try? itemsContainer.decode(RawThreadItem.self) {
                items.append(item)
            } else {
                // Skip the bad element by decoding as opaque JSON
                _ = try? itemsContainer.decode(AnyCodableSkip.self)
                dropped += 1
            }
        }
        thread = items
        droppedCount = dropped
    }
}

/// Opaque Decodable that consumes one JSON value (used to skip malformed array elements).
private struct AnyCodableSkip: Decodable {}

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

// MARK: - PipelineHeartbeat

struct PipelineHeartbeat: Decodable, Identifiable {
    let pipeline: String
    let lastEventAt: Date?
    let stalenessMinutes: Double?

    var id: String { pipeline }

    enum CodingKeys: String, CodingKey {
        case pipeline
        case lastEventAt = "last_event_at"
        case stalenessMinutes = "staleness_minutes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pipeline = try container.decode(String.self, forKey: .pipeline)

        if let raw = try container.decodeIfPresent(String.self, forKey: .lastEventAt) {
            let fmtFrac = ISO8601DateFormatter()
            fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fmtBasic = ISO8601DateFormatter()
            fmtBasic.formatOptions = [.withInternetDateTime]
            lastEventAt = fmtFrac.date(from: raw) ?? fmtBasic.date(from: raw)
        } else {
            lastEventAt = nil
        }

        stalenessMinutes = try container.decodeIfPresent(Double.self, forKey: .stalenessMinutes)
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
    case misconfigured(String)
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .misconfigured(let message):
            return message
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

// MARK: - Truth Graph Models (read-only)

struct TruthGraphResponse: Decodable, Hashable {
    let ok: Bool
    let interactionId: String
    let hydration: TruthGraphHydration
    let lane: String
    let suggestedRepairs: [TruthGraphSuggestedRepair]
    let warnings: [String]
    let functionVersion: String?
    let ms: Int?

    enum CodingKeys: String, CodingKey {
        case ok
        case interactionId = "interaction_id"
        case hydration
        case lane
        case suggestedRepairs = "suggested_repairs"
        case warnings
        case functionVersion = "function_version"
        case ms
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container.decode(Bool.self, forKey: .ok)) ?? false
        interactionId = (try? container.decode(String.self, forKey: .interactionId)) ?? ""
        hydration = (try? container.decode(TruthGraphHydration.self, forKey: .hydration)) ?? .empty
        lane = (try? container.decode(String.self, forKey: .lane)) ?? "unknown"
        functionVersion = try container.decodeIfPresent(String.self, forKey: .functionVersion)
        ms = try container.decodeIfPresent(Int.self, forKey: .ms)

        // Lossy array decode: skip individual malformed repair objects instead of
        // failing the entire response (truth surface should degrade gracefully).
        var decodedRepairs: [TruthGraphSuggestedRepair] = []
        if var repairsContainer = try? container.nestedUnkeyedContainer(forKey: .suggestedRepairs) {
            while !repairsContainer.isAtEnd {
                if let repair = try? repairsContainer.decode(TruthGraphSuggestedRepair.self) {
                    decodedRepairs.append(repair)
                } else {
                    _ = try? repairsContainer.decode(AnyCodableSkip.self)
                }
            }
        }
        suggestedRepairs = decodedRepairs

        var decodedWarnings: [String] = []
        if var warningsContainer = try? container.nestedUnkeyedContainer(forKey: .warnings) {
            while !warningsContainer.isAtEnd {
                if let warning = try? warningsContainer.decode(String.self) {
                    decodedWarnings.append(warning)
                } else {
                    _ = try? warningsContainer.decode(AnyCodableSkip.self)
                }
            }
        }
        warnings = decodedWarnings
    }
}

struct TruthGraphHydration: Decodable, Hashable {
    let callsRaw: Bool
    let interactions: Bool
    let conversationSpans: Bool
    let evidenceEvents: Bool
    let spanAttributions: Bool
    let journalClaims: Bool
    let reviewQueue: Bool

    enum CodingKeys: String, CodingKey {
        case callsRaw = "calls_raw"
        case interactions
        case conversationSpans = "conversation_spans"
        case evidenceEvents = "evidence_events"
        case spanAttributions = "span_attributions"
        case journalClaims = "journal_claims"
        case reviewQueue = "review_queue"
    }

    // `init(from:)` suppresses the synthesized memberwise init, but we still want
    // to construct instances (e.g. `.empty`) without going through a decoder.
    init(
        callsRaw: Bool,
        interactions: Bool,
        conversationSpans: Bool,
        evidenceEvents: Bool,
        spanAttributions: Bool,
        journalClaims: Bool,
        reviewQueue: Bool
    ) {
        self.callsRaw = callsRaw
        self.interactions = interactions
        self.conversationSpans = conversationSpans
        self.evidenceEvents = evidenceEvents
        self.spanAttributions = spanAttributions
        self.journalClaims = journalClaims
        self.reviewQueue = reviewQueue
    }

    static let empty = TruthGraphHydration(
        callsRaw: false,
        interactions: false,
        conversationSpans: false,
        evidenceEvents: false,
        spanAttributions: false,
        journalClaims: false,
        reviewQueue: false
    )

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callsRaw = (try? container.decode(Bool.self, forKey: .callsRaw)) ?? false
        interactions = (try? container.decode(Bool.self, forKey: .interactions)) ?? false
        conversationSpans = (try? container.decode(Bool.self, forKey: .conversationSpans)) ?? false
        evidenceEvents = (try? container.decode(Bool.self, forKey: .evidenceEvents)) ?? false
        spanAttributions = (try? container.decode(Bool.self, forKey: .spanAttributions)) ?? false
        journalClaims = (try? container.decode(Bool.self, forKey: .journalClaims)) ?? false
        reviewQueue = (try? container.decode(Bool.self, forKey: .reviewQueue)) ?? false
    }
}

struct TruthGraphSuggestedRepair: Decodable, Hashable, Identifiable {
    let action: String
    let label: String
    let idempotencyKey: String

    var id: String {
        "\(action):\(idempotencyKey)"
    }

    enum CodingKeys: String, CodingKey {
        case action
        case label
        case idempotencyKey = "idempotency_key"
    }
}
