import Foundation

/// Sends truth-forcing telemetry from iOS surfaces to the backend for validation / KPI dashboards.
///
/// Security posture: the server endpoint requires `X-Edge-Secret` (internal-only) + `X-Source=ios_redline`,
/// so this client should only attempt to send when Internal Mode + edge secret are available.
@MainActor
final class TriageTelemetryService {
    static let shared = TriageTelemetryService()

    private enum Config {
        static let supabaseURLKey = "SUPABASE_URL"
        static let supabaseAnonKeyKey = "SUPABASE_ANON_KEY"
        static let fallbackURL = URL(string: "https://example.invalid")!
    }

    private let endpointURL: URL
    private let iso8601 = ISO8601DateFormatter()

    private init() {
        let env = ProcessInfo.processInfo.environment
        let supabaseUrlString = (env[Config.supabaseURLKey]
            ?? (Bundle.main.object(forInfoDictionaryKey: Config.supabaseURLKey) as? String)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let supabaseURL = URL(string: supabaseUrlString) ?? Config.fallbackURL
        endpointURL = supabaseURL.appendingPathComponent("functions/v1/triage-telemetry")
    }

    func track(
        surface: String,
        eventType: String,
        payload: [String: Any] = [:],
        occurredAt: Date = Date()
    ) {
        Task {
            await send(
                surface: surface,
                eventType: eventType,
                payload: payload,
                occurredAt: occurredAt
            )
        }
    }

    private func send(
        surface: String,
        eventType: String,
        payload: [String: Any],
        occurredAt: Date
    ) async {
        guard endpointURL != Config.fallbackURL else { return }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios_redline", forHTTPHeaderField: "X-Source")

        // Adds Bearer+apikey headers and (in DEBUG internal mode) X-Edge-Secret.
        BootstrapService.shared.applyTelemetryAuthHeaders(to: &request)

        // Skip noisy network calls if we don't have an edge secret attached.
        if request.value(forHTTPHeaderField: "X-Edge-Secret") == nil {
            return
        }

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let buildNumber = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"

        let body: [String: Any] = [
            "event_name": "triage_surface_interaction",
            "surface": surface,
            "event_type": eventType,
            "occurred_at_utc": iso8601.string(from: occurredAt),
            "payload": payload.merging([
                "app_version": appVersion,
                "build_number": buildNumber,
            ]) { _, new in new },
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            _ = try await URLSession.shared.data(for: request)
        } catch {
            // Telemetry must never block UX.
            #if DEBUG
            print("[TriageTelemetryService] send failed: \(error.localizedDescription)")
            #endif
        }
    }
}

