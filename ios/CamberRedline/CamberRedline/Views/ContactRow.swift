import SwiftUI

struct ContactRow: View {
    let contact: Contact

    var body: some View {
        HStack(spacing: 12) {
            initialsAvatar

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(contact.name)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)

                    Spacer()

                    if let relativeTime = relativeTimeString {
                        Text(relativeTime)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 4) {
                    if let interactionIcon = interactionIcon {
                        Image(systemName: interactionIcon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let dir = contact.lastDirection {
                        Image(systemName: dir == "outbound" ? "arrow.up.right" : "arrow.down.left")
                            .font(.caption2)
                            .foregroundStyle(dir == "outbound" ? .blue : .green)
                    }

                    Text(previewText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if contact.ungradedCount > 0 {
                Text("\(contact.ungradedCount)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange, in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Initials Avatar

    private var initialsAvatar: some View {
        let initials = contact.name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()

        return Text(initials)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color(white: 0.25))
            .clipShape(Circle())
    }

    // MARK: - Preview Text

    private var previewText: String {
        if let snippet = contact.lastSnippet, !snippet.isEmpty {
            return snippet
        }
        let parts: [String] = [
            contact.callCount > 0 ? "\(contact.callCount) calls" : nil,
            contact.smsCount > 0 ? "\(contact.smsCount) messages" : nil,
        ].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    private var interactionIcon: String? {
        switch contact.lastInteractionType {
        case "sms":
            return "message.fill"
        case "call":
            return "phone.fill"
        default:
            return nil
        }
    }

    // MARK: - Relative Time

    private var relativeTimeString: String? {
        guard let lastActivity = contact.lastActivity else { return nil }
        guard let date = parseDate(lastActivity) else { return nil }
        return relativeString(from: date)
    }

    nonisolated(unsafe) private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let postgresFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ssxx"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    nonisolated(unsafe) private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private func parseDate(_ string: String) -> Date? {
        if let d = Self.isoFormatterFractional.date(from: string) { return d }
        if let d = Self.isoFormatterBasic.date(from: string) { return d }
        // Postgres format: "2026-02-23 18:36:12+00"
        return Self.postgresFormatter.date(from: string)
    }

    private func relativeString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3_600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3_600))h" }
        if interval < 604_800 { return "\(Int(interval / 86_400))d" }
        return Self.shortDateFormatter.string(from: date)
    }
}
