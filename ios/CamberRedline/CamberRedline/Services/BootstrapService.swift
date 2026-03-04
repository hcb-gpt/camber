import Foundation
import Observation
import os

private enum BootstrapSmokeAutomation {
    static let launchFlag = "--smoke-drive"
    static let truthSurfaceLocalFlag = "--smoke-truth-surface-local"
    static let writeLockRecoveryFlag = "--smoke-write-lock-recovery"
    static let logger = Logger(subsystem: "CamberRedline", category: "smoke")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }

    static var truthSurfaceLocalEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(truthSurfaceLocalFlag)
    }

    static var writeLockRecoveryEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(writeLockRecoveryFlag)
    }

    static var shouldForceWriteLock: Bool {
        writeLockRecoveryEnabled && ProcessInfo.processInfo.environment["SMOKE_FORCE_WRITE_LOCK"] == "1"
    }
}

private enum BootstrapLearningLoopMetrics {
    static let logger = Logger(subsystem: "CamberRedline", category: "learning_loop")

    static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}

// MARK: - BootstrapService

@MainActor
@Observable
final class BootstrapService {
    static let shared = BootstrapService()

    private enum Config {
        static let supabaseURLKey = "SUPABASE_URL"
        static let supabaseAnonKeyKey = "SUPABASE_ANON_KEY"
        static let fallbackURL = URL(string: "https://example.invalid")!
    }

    #if DEBUG
    private enum InternalModeConfig {
        static let enabledKey = "bootstrap_internal_mode_enabled_v1"
        static let writeStubEnabledKey = "bootstrap_internal_mode_write_stub_enabled_v1"
        static let keychainService = "CamberRedline"
        static let keychainAccount = "bootstrap_edge_secret_v1"
    }
    #endif

    private let baseURL: URL
    private let anonKey: String

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var cachedReviewProjects: [ReviewProject] = []
    private var cachedReviewProjectsAt: Date?
    private let reviewProjectsCacheTTL: TimeInterval = 5 * 60

    private(set) var writeLockState: BootstrapWriteLockState?

    var writesLockedBannerText: String? {
        guard let state = effectiveWriteLockState else { return nil }

        var message = state.error.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            message = "Attribution writes temporarily locked."
        }
        if !message.contains("Truth surface remains readable") {
            message += " Truth surface remains readable."
        }
        #if DEBUG
        if shouldUseWriteStubWhenLocked {
            message = "Attribution writes temporarily locked. Local write stub is active for UI testing only (no server writes)."
        }
        #endif
        var meta: [String] = []
        if let functionVersion = state.functionVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !functionVersion.isEmpty {
            meta.append(functionVersion)
        }
        if let requestId = state.requestId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestId.isEmpty {
            meta.append("request_id: \(requestId)")
        }
        if !meta.isEmpty {
            message += " (\(meta.joined(separator: ", ")))"
        }
        return message
    }

    private init() {
        let supabaseUrlString = (Bundle.main.object(forInfoDictionaryKey: Config.supabaseURLKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let anonKey = (Bundle.main.object(forInfoDictionaryKey: Config.supabaseAnonKeyKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let supabaseURL = URL(string: supabaseUrlString) ?? Config.fallbackURL

        if supabaseURL == Config.fallbackURL || anonKey.isEmpty {
            assertionFailure("Missing \(Config.supabaseURLKey) / \(Config.supabaseAnonKeyKey) in Info.plist")
        }

        self.anonKey = anonKey
        self.baseURL = supabaseURL.appendingPathComponent("functions/v1/bootstrap-review")

        session = URLSession.shared
        decoder = JSONDecoder()
        encoder = JSONEncoder()

        #if DEBUG
        if BootstrapSmokeAutomation.writeLockRecoveryEnabled {
            // Keep smoke runs deterministic: enable internal mode so X-Edge-Secret can be sent when available.
            UserDefaults.standard.set(true, forKey: InternalModeConfig.enabledKey)
        }
        if BootstrapSmokeAutomation.shouldForceWriteLock {
            writeLockState = BootstrapWriteLockState(
                statusCode: 403,
                errorCode: "invalid_auth",
                error: "Write actions require X-Edge-Secret",
                functionVersion: "bootstrap-review_v1.3.2",
                requestId: "smoke-forced-lock",
                observedAt: Date()
            )
        }
        #endif
    }

    private var edgeSharedSecret: String? {
        #if DEBUG
        let raw = (ProcessInfo.processInfo.environment["EDGE_SHARED_SECRET"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
        #else
        nil
        #endif
    }

    private enum EdgeSecretPolicy {
        case never
        case bootstrapWritesOnly
    }

    private var recoveryProbeReviewQueueId: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SMOKE_RECOVERY_PROBE_QUEUE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return override
        }
        #endif
        // UUID-shaped sentinel lets backend reach handler validation path after auth gate.
        return "00000000-0000-0000-0000-000000000000"
    }

    func clearWriteLock() {
        writeLockState = nil
    }

    func recoverWriteAccess() async -> BootstrapWriteRecoveryOutcome {
        if let preflightLockState {
            return .stillLocked(preflightLockState)
        }

        guard let lockedStateAtProbeStart = writeLockState else {
            return .unlocked(statusCode: nil, requestId: nil)
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: "undo")]
        guard let url = components.url else {
            writeLockState = lockedStateAtProbeStart
            return .failed(
                message: "Failed to construct recovery request URL.",
                statusCode: nil,
                requestId: nil
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request, edgeSecretPolicy: .bootstrapWritesOnly, isWrite: true)

        do {
            request.httpBody = try encoder.encode(
                UndoRequest(reviewQueueId: recoveryProbeReviewQueueId)
            )
        } catch {
            writeLockState = lockedStateAtProbeStart
            return .failed(
                message: "Failed to encode recovery request.",
                statusCode: nil,
                requestId: nil
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                writeLockState = lockedStateAtProbeStart
                return .failed(
                    message: "Invalid recovery response.",
                    statusCode: nil,
                    requestId: nil
                )
            }

            let requestId = http.value(forHTTPHeaderField: "x-request-id")
                ?? http.value(forHTTPHeaderField: "sb-request-id")

            if let lockState = makeWriteLockState(
                statusCode: http.statusCode,
                data: data,
                requestId: requestId
            ) {
                writeLockState = lockState
                BootstrapLearningLoopMetrics.log(
                    "KPI_EVENT AUTH_LOCK_RECOVERY_LOCKED status_code=\(lockState.statusCode) request_id=\(lockState.requestId ?? "missing") error_code=\(lockState.errorCode ?? "missing")"
                )
                return .stillLocked(lockState)
            }

            let payload = try? decoder.decode(RecoveryProbePayload.self, from: data)
            if isRecoveryProbeSuccess(statusCode: http.statusCode, payload: payload) {
                writeLockState = nil
                BootstrapLearningLoopMetrics.log(
                    "KPI_EVENT AUTH_LOCK_RECOVERY_UNLOCKED status_code=\(http.statusCode) request_id=\(requestId ?? payload?.requestId ?? "missing")"
                )
                return .unlocked(
                    statusCode: http.statusCode,
                    requestId: requestId ?? payload?.requestId
                )
            }

            let errorCode = payload?.errorCode ?? "missing"
            let effectiveRequestId = requestId ?? payload?.requestId
            // Non-success/non-auth responses do not prove recovery; keep lock engaged.
            writeLockState = lockedStateAtProbeStart
            BootstrapLearningLoopMetrics.log(
                "KPI_EVENT AUTH_LOCK_RECOVERY_PRESERVED status_code=\(http.statusCode) request_id=\(effectiveRequestId ?? "missing") error_code=\(errorCode)"
            )
            return .failed(
                message: recoveryProbeFailureMessage(statusCode: http.statusCode, payload: payload),
                statusCode: http.statusCode,
                requestId: effectiveRequestId
            )
        } catch {
            writeLockState = lockedStateAtProbeStart
            BootstrapLearningLoopMetrics.log(
                "KPI_EVENT AUTH_LOCK_RECOVERY_FAILED message=\(error.localizedDescription)"
            )
            return .failed(
                message: error.localizedDescription,
                statusCode: nil,
                requestId: nil
            )
        }
    }

    #if DEBUG
    func isInternalModeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: InternalModeConfig.enabledKey)
    }

    func setInternalModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: InternalModeConfig.enabledKey)
        if !enabled {
            clearWriteLock()
        }
    }

    func isWriteStubEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: InternalModeConfig.writeStubEnabledKey)
    }

    func setWriteStubEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: InternalModeConfig.writeStubEnabledKey)
    }

    func hasStoredEdgeSecret() -> Bool {
        (try? KeychainStore.readString(service: InternalModeConfig.keychainService, account: InternalModeConfig.keychainAccount)) != nil
    }

    func storeEdgeSecret(_ secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try KeychainStore.writeString(
            trimmed,
            service: InternalModeConfig.keychainService,
            account: InternalModeConfig.keychainAccount,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        clearWriteLock()
    }

    func wipeStoredEdgeSecret() throws {
        try KeychainStore.deleteItem(service: InternalModeConfig.keychainService, account: InternalModeConfig.keychainAccount)
        clearWriteLock()
    }

    private func edgeSecretForWriteRequest() -> String? {
        guard isInternalModeEnabled() else { return nil }

        if let edgeSharedSecret {
            return edgeSharedSecret
        }
        return try? KeychainStore.readString(service: InternalModeConfig.keychainService, account: InternalModeConfig.keychainAccount)
    }

    private var shouldUseWriteStubWhenLocked: Bool {
        isInternalModeEnabled() && isWriteStubEnabled()
    }

    private func shouldUseWriteStub(hasLockState: Bool) -> Bool {
        if BootstrapSmokeAutomation.truthSurfaceLocalEnabled {
            return true
        }
        return hasLockState && shouldUseWriteStubWhenLocked
    }

    private func stubWriteResponse(action: String, bodyData: Data) throws -> Data {
        let payload = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
        let queueId = (payload["review_queue_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown_queue"
        let requestId = "stub_\(action)__\(queueId)"

        var object: [String: Any] = [
            "ok": true,
            "request_id": requestId
        ]
        switch action {
        case "resolve":
            object["review_queue_id"] = queueId
            object["was_already_resolved"] = false
            if let chosenProjectId = payload["project_id"] as? String {
                object["chosen_project_id"] = chosenProjectId
            }
        case "dismiss", "undo", "skip":
            break
        default:
            break
        }

        let data = try JSONSerialization.data(withJSONObject: object)
        BootstrapLearningLoopMetrics.log(
            "KPI_EVENT WRITE_STUB_USED action=\(action) queue=\(queueId) request_id=\(requestId)"
        )
        return data
    }
    #endif

    private var preflightLockState: BootstrapWriteLockState? {
        #if DEBUG
        guard !BootstrapSmokeAutomation.truthSurfaceLocalEnabled else { return nil }
        guard isInternalModeEnabled() else {
            return BootstrapWriteLockState(
                statusCode: 403,
                errorCode: "invalid_auth",
                error: "Privileged attribution writes disabled (Internal Mode off).",
                functionVersion: nil,
                requestId: nil,
                observedAt: Date()
            )
        }
        guard edgeSecretForWriteRequest() == nil else { return nil }
        return BootstrapWriteLockState(
            statusCode: 403,
            errorCode: "invalid_auth",
            error: "Privileged attribution writes enabled, but no X-Edge-Secret is stored.",
            functionVersion: nil,
            requestId: nil,
            observedAt: Date()
        )
        #else
        nil
        #endif
    }

    private var effectiveWriteLockState: BootstrapWriteLockState? {
        writeLockState ?? preflightLockState
    }

    private func applyAuthHeaders(
        to request: inout URLRequest,
        edgeSecretPolicy: EdgeSecretPolicy = .never,
        isWrite: Bool = false
    ) {
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")

        guard isWrite, edgeSecretPolicy == .bootstrapWritesOnly else { return }

        #if DEBUG
        if let edgeSecret = edgeSecretForWriteRequest() {
            request.setValue(edgeSecret, forHTTPHeaderField: "X-Edge-Secret")
        }
        #endif
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

        var request = URLRequest(url: url)
        applyAuthHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

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
    ) async throws -> BootstrapActionResponse {
        let body = DismissRequest(
            reviewQueueId: queueId,
            reason: reason,
            notes: notes,
            userId: userId
        )
        let data = try await post(action: "dismiss", body: body)
        return try decodeOkResponse(data, action: "dismiss")
    }

    // MARK: - Undo

    @discardableResult
    func undo(queueId: String) async throws -> BootstrapActionResponse {
        let body = UndoRequest(reviewQueueId: queueId)
        let data = try await post(action: "undo", body: body)
        return try decodeOkResponse(data, action: "undo")
    }

    // MARK: - Assistant Context

    private var assistantContextURL: URL {
        baseURL.deletingLastPathComponent().appendingPathComponent("assistant-context")
    }

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

        var request = URLRequest(url: url)
        applyAuthHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
        do {
            let decoded = try decoder.decode(AssistantContextPacket.self, from: data)
            if BootstrapSmokeAutomation.isEnabled,
               let http = response as? HTTPURLResponse {
                let requestId =
                    http.value(forHTTPHeaderField: "x-request-id") ??
                    http.value(forHTTPHeaderField: "sb-request-id")

                BootstrapSmokeAutomation.logger.log(
                    "SMOKE_EVENT ASSISTANT_CONTEXT request_id=\(requestId ?? "missing", privacy: .public) version=\(decoded.functionVersion ?? "", privacy: .public)"
                )
            }
            return decoded
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
            #if DEBUG
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8>"
            print("[AssistantContextDecode] path=\(path) error=\(error)")
            print("[AssistantContextDecode] payload_preview=\(preview)")
            #endif
            throw BootstrapServiceError.apiError("Assistant context decode failure at path: \(path)")
        }
    }

    // MARK: - Assistant Chat

    private var assistantChatURL: URL {
        baseURL.deletingLastPathComponent().appendingPathComponent("redline-assistant")
    }

    private var assistantFeedbackURL: URL {
        baseURL.deletingLastPathComponent().appendingPathComponent("assistant-feedback")
    }

    func streamAssistantChat(
        message: String,
        contactId: String? = nil,
        projectId: String? = nil,
        history: [AssistantChatHistoryMessage] = []
    ) async throws -> AssistantChatSession {
        var request = URLRequest(url: assistantChatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request)

        let tz = TimeZone.current
        let tzOffsetMinutes = Int(tz.secondsFromGMT() / 60)

        let body: [String: Any?] = [
            "message": message,
            "contact_id": contactId,
            "project_id": projectId,
            "client_tz_name": tz.identifier,
            "client_utc_offset_minutes": tzOffsetMinutes,
            "response_style": "superintendent_v1",
            "history": history.map { ["role": $0.role, "content": $0.content] }
        ]
        let filteredBody = body.compactMapValues { $0 }

        request.httpBody = try JSONSerialization.data(withJSONObject: filteredBody)
        let payloadString = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "{}"

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BootstrapServiceError.invalidResponse
        }

        let requestId = http.value(forHTTPHeaderField: "x-request-id")
            ?? http.value(forHTTPHeaderField: "sb-request-id")
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
        applyAuthHeaders(to: &request)
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let decoded = try decoder.decode(AssistantFeedbackResponse.self, from: data)
        guard decoded.ok else {
            throw BootstrapServiceError.apiError(decoded.error ?? "assistant feedback returned ok=false")
        }
        return decoded
    }

    // MARK: - Helpers

    private func post<T: Encodable>(action: String, body: T) async throws -> Data {
        let bodyData = try encoder.encode(body)
        let lockState = effectiveWriteLockState

        #if DEBUG
        if shouldUseWriteStub(hasLockState: lockState != nil) {
            return try stubWriteResponse(action: action, bodyData: bodyData)
        }
        #endif

        if let lockState {
            throw BootstrapServiceError.writesLocked(lockState)
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: action)]

        guard let url = components.url else {
            throw BootstrapServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request, edgeSecretPolicy: .bootstrapWritesOnly, isWrite: true)
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)
        do {
            try validateHTTPResponse(response, data: data, isWrite: true)
        } catch let error as BootstrapServiceError {
            guard case .writesLocked = error else {
                throw error
            }
            #if DEBUG
            if shouldUseWriteStub(hasLockState: true) {
                return try stubWriteResponse(action: action, bodyData: bodyData)
            }
            #endif
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            return data
        }

        let requestId = http.value(forHTTPHeaderField: "x-request-id")
            ?? http.value(forHTTPHeaderField: "sb-request-id")
        guard let requestId, !requestId.isEmpty else {
            return data
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["request_id"] == nil
        else {
            return data
        }

        var patchedObject = object
        patchedObject["request_id"] = requestId
        guard let patchedData = try? JSONSerialization.data(withJSONObject: patchedObject) else {
            return data
        }
        return patchedData
    }

    private func decodeOkResponse(_ data: Data, action: String) throws -> BootstrapActionResponse {
        guard let parsed = try? decoder.decode(BootstrapActionResponse.self, from: data) else {
            return BootstrapActionResponse(ok: true, error: nil, requestId: nil)
        }
        guard parsed.ok else {
            throw BootstrapServiceError.apiError(
                parsed.error ?? "Unknown error from \(action)"
            )
        }
        return parsed
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data? = nil, isWrite: Bool = false) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BootstrapServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let requestId = http.value(forHTTPHeaderField: "x-request-id")
                ?? http.value(forHTTPHeaderField: "sb-request-id")

            if isWrite,
               let lockState = makeWriteLockState(
                   statusCode: http.statusCode,
                   data: data,
                   requestId: requestId
               ) {
                writeLockState = lockState
                BootstrapLearningLoopMetrics.log(
                    "KPI_EVENT AUTH_LOCK_SET status_code=\(http.statusCode) error_code=\(lockState.errorCode ?? "missing") request_id=\(requestId ?? "missing") function_version=\(lockState.functionVersion ?? "missing")"
                )
                throw BootstrapServiceError.writesLocked(lockState)
            }

            if let data,
               let payload = try? decoder.decode(EdgeFunctionErrorPayload.self, from: data),
               let error = payload.error?.trimmingCharacters(in: .whitespacesAndNewlines),
               !error.isEmpty {

                if let requestId, !requestId.isEmpty {
                    throw BootstrapServiceError.apiError("\(error) (request_id: \(requestId))")
                }
                throw BootstrapServiceError.apiError(error)
            }

            if let requestId, !requestId.isEmpty {
                throw BootstrapServiceError.apiError("HTTP error \(http.statusCode) (request_id: \(requestId)).")
            }
            throw BootstrapServiceError.httpError(statusCode: http.statusCode)
        }
    }

    private func isRecoveryProbeSuccess(
        statusCode: Int,
        payload: RecoveryProbePayload?
    ) -> Bool {
        if (200...299).contains(statusCode), payload?.ok == true {
            return true
        }

        // Probe sends a UUID sentinel; item_not_found means auth gate passed.
        if statusCode == 404, payload?.errorCode == "item_not_found" {
            return true
        }

        return false
    }

    private func recoveryProbeFailureMessage(
        statusCode: Int,
        payload: RecoveryProbePayload?
    ) -> String {
        if let errorCode = payload?.errorCode, let error = payload?.error, !error.isEmpty {
            return "Recovery probe failed (\(statusCode)): \(errorCode): \(error)"
        }
        if let error = payload?.error, !error.isEmpty {
            return "Recovery probe failed (\(statusCode)): \(error)"
        }
        if let errorCode = payload?.errorCode {
            return "Recovery probe failed (\(statusCode)): \(errorCode)"
        }
        return "Recovery probe failed (HTTP \(statusCode))."
    }

    private func makeWriteLockState(
        statusCode: Int,
        data: Data?,
        requestId: String?
    ) -> BootstrapWriteLockState? {
        guard [401, 403].contains(statusCode) else { return nil }

        let payload = data.flatMap { try? decoder.decode(EdgeFunctionErrorPayload.self, from: $0) }
        let rawError = payload?.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorCode = payload?.errorCode
        let functionVersion = payload?.functionVersion

        if let errorCode,
           errorCode != "invalid_auth",
           !rawError.contains("Write actions require X-Edge-Secret")
        {
            return nil
        }

        let lockError = rawError.isEmpty ? "Write actions require privileged auth." : rawError
        return BootstrapWriteLockState(
            statusCode: statusCode,
            errorCode: errorCode,
            error: lockError,
            functionVersion: functionVersion,
            requestId: requestId,
            observedAt: Date()
        )
    }
}

private struct EdgeFunctionErrorPayload: Decodable {
    let ok: Bool?
    let error: String?
    let errorCode: String?
    let functionVersion: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case errorCode = "error_code"
        case functionVersion = "function_version"
    }
}

private struct RecoveryProbePayload: Decodable {
    let ok: Bool?
    let error: String?
    let errorCode: String?
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case errorCode = "error_code"
        case requestId = "request_id"
    }
}

struct BootstrapWriteLockState: Equatable {
    let statusCode: Int
    let errorCode: String?
    let error: String
    let functionVersion: String?
    let requestId: String?
    let observedAt: Date
}

enum BootstrapWriteRecoveryOutcome: Equatable {
    case unlocked(statusCode: Int?, requestId: String?)
    case stillLocked(BootstrapWriteLockState)
    case failed(message: String, statusCode: Int?, requestId: String?)
}

struct ResolveResponse: Decodable {
    let ok: Bool
    let reviewQueueId: String?
    let chosenProjectId: String?
    let wasAlreadyResolved: Bool?
    let requestId: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case reviewQueueId = "review_queue_id"
        case chosenProjectId = "chosen_project_id"
        case wasAlreadyResolved = "was_already_resolved"
        case requestId = "request_id"
        case error
    }
}

struct BootstrapActionResponse: Decodable {
    let ok: Bool
    let error: String?
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case requestId = "request_id"
    }
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
    case writesLocked(BootstrapWriteLockState)

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
        case .writesLocked(let state):
            var message = "Attribution writes temporarily locked. Truth surface remains readable."
            if let functionVersion = state.functionVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
               !functionVersion.isEmpty {
                message += " (\(functionVersion))"
            }
            if let requestId = state.requestId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !requestId.isEmpty {
                message += " (request_id: \(requestId))"
            }
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
