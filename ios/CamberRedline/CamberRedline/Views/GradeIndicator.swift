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
        guard let grade else { return .gray }
        switch grade {
        case GradeType.confirm.rawValue:
            return .green
        case GradeType.reject.rawValue:
            return .red
        case GradeType.correct.rawValue:
            return .orange
        default:
            return .gray
        }
    }

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 16))
            .foregroundStyle(iconColor)
    }
}
