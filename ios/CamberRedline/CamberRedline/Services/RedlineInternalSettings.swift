import Foundation

enum RedlineInternalSettings {
    enum Keys {
        static let truthGraphStatusCardEnabled = "redline.internal.truth_graph_status_card_enabled"
        static let edgeSecret = "redline.internal.edge_secret"
    }

    static let edgeSource = "redline_ios"

    static var truthGraphStatusCardEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.truthGraphStatusCardEnabled)
    }

    static var edgeSecret: String? {
        let raw = UserDefaults.standard.string(forKey: Keys.edgeSecret) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

