import Foundation

enum TriageSurfaceMode: String, CaseIterable, Identifiable {
    case contractor
    case dev

    var id: String { rawValue }

    var label: String {
        switch self {
        case .contractor: "Contractor"
        case .dev: "Dev"
        }
    }

    var isDeveloperMode: Bool {
        self == .dev
    }
}
