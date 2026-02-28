import SwiftUI

struct ContactRow: View {
    let contact: Contact

    // MARK: - Layout constants

    private let avatarSize: CGFloat = 44

    // MARK: - Body

    var body: some View {
        HStack(spacing: 16) {
            initialsAvatar

            VStack(alignment: .leading, spacing: 6) {

                // Row 1: name + timestamp
                HStack(alignment: .firstTextBaseline) {
                    Text(contact.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(white: 0.93))
                        .lineLimit(1)

                    Spacer()

                    if let relativeTime = relativeTimeString {
                        Text(relativeTime)
                            .font(.system(size: 13, weight: .regular).monospacedDigit())
                            .foregroundStyle(Color(white: 0.38))
                    }
                }

                // Row 2: preview snippet
                Text(previewText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.42))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Initials Avatar

    private var initialsAvatar: some View {
        let count = contact.ungradedCount
        let label = count > 99 ? "99+" : "\(count)"

        return Text(label)
            .font(.system(size: label.count > 2 ? 12 : 15, weight: .semibold).monospacedDigit())
            .foregroundStyle(count > 0 ? Color(red: 0.95, green: 0.62, blue: 0.23) : Color(white: 0.52))
            .frame(width: avatarSize, height: avatarSize)
            .background(count > 0 ? Color(red: 0.20, green: 0.12, blue: 0.05) : Color(white: 0.12))
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(
                        count > 0 ? Color(red: 0.43, green: 0.26, blue: 0.11) : Color(white: 0.20),
                        lineWidth: 0.5
                    )
            )
    }

    // MARK: - Preview Text

    private var previewText: String {
        if let snippet = contact.lastSnippet, !snippet.isEmpty {
            // Truncate to ~80 chars for row preview
            if snippet.count > 80 {
                return String(snippet.prefix(77)) + "…"
            }
            return snippet
        }

        if let lastActivity = contact.lastActivity, !lastActivity.isEmpty {
            let interactionType = contact.lastInteractionType?.lowercased()
            if interactionType == "call" {
                return "Phone call"
            }
            if interactionType == "sms" {
                return "Text message"
            }
            return "Recent activity"
        }

        return "No recent activity"
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

    private static let postgresFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ssxx"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private func parseDate(_ string: String) -> Date? {
        if let d = Self.isoFormatterFractional.date(from: string) { return d }
        if let d = Self.isoFormatterBasic.date(from: string) { return d }
        return Self.postgresFormatter.date(from: string)
    }

    private func relativeString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60        { return "now" }
        if interval < 3_600     { return "\(Int(interval / 60))m" }
        if interval < 86_400    { return "\(Int(interval / 3_600))h" }
        if interval < 604_800   { return "\(Int(interval / 86_400))d" }
        return Self.shortDateFormatter.string(from: date)
    }
}

// MARK: - Color hex helper

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
