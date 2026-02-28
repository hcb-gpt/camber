import SwiftUI

struct GradeIndicator: View {
    let grade: String?

    private var iconName: String {
        guard let grade else { return "circle" }
        switch grade {
        case GradeType.confirm.rawValue:
            return "checkmark.circle.fill"
        case GradeType.reject.rawValue:
            return "xmark.circle.fill"
        case GradeType.correct.rawValue:
            return "pencil.circle.fill"
        default:
            return "circle"
        }
    }

    private var iconColor: Color {
        guard let grade else { return Color(.systemGray) }
        switch grade {
        case GradeType.confirm.rawValue:
            return .green
        case GradeType.reject.rawValue:
            return .red
        case GradeType.correct.rawValue:
            return .orange
        default:
            // Unrecognised grade — use adaptive gray that reads on #1C1C1E
            return Color(.systemGray)
        }
    }

    private var gradeLabel: String {
        guard let grade else { return "Ungraded" }
        switch grade {
        case GradeType.confirm.rawValue: return "Confirmed"
        case GradeType.reject.rawValue: return "Rejected"
        case GradeType.correct.rawValue: return "Corrected"
        default: return "Ungraded"
        }
    }

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 16))
            .foregroundStyle(iconColor)
            .accessibilityLabel(gradeLabel)
    }
}
