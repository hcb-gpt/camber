import SwiftUI

struct ContactRow: View {
    let contact: Contact

    // MARK: - Layout constants

    private let avatarSize: CGFloat = 44
    private let badgeFont = Font.system(size: 11, weight: .semibold)

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            initialsAvatar

            VStack(alignment: .leading, spacing: 4) {

                // Row 1: name + last-activity timestamp
                HStack(alignment: .firstTextBaseline) {
                    Text(contact.name)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer()

                    if let relativeTime = relativeTimeString {
                        Text(relativeTime)
                            .font(.subheadline)
                            .foregroundStyle(Color(hex: 0x8E8E93))
                    }
                }

                // Row 2: direction + preview snippet
                HStack(spacing: 4) {
                    if let dir = contact.lastDirection {
                        Image(systemName: dir == "outbound" ? "arrow.up.right" : "arrow.down.left")
                            .font(.caption2)
                            .foregroundStyle(dir == "outbound" ? .blue : .green)
                    }

                    Text(previewText)
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: 0x8E8E93))
                        .lineLimit(1)
                }

                // Row 3: call count badge, SMS count badge, ungraded badge
                HStack(spacing: 6) {
                    if contact.callCount > 0 {
                        countBadge(
                            icon: "phone.fill",
                            count: contact.callCount,
                            tint: Color(hex: 0x3A3A3C)
                        )
                    }

                    if contact.smsCount > 0 {
                        countBadge(
                            icon: "message.fill",
                            count: contact.smsCount,
                            tint: Color(hex: 0x3A3A3C)
                        )
                    }

                    if contact.ungradedCount > 0 {
                        Text("\(contact.ungradedCount) ungraded")
                            .font(badgeFont)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.orange, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Count badge

    private func countBadge(icon: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text("\(count)")
                .font(badgeFont)
        }
        .foregroundStyle(Color(hex: 0x8E8E93))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint, in: Capsule())
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
            .frame(width: avatarSize, height: avatarSize)
            .background(Color(white: 0.22))
            .clipShape(Circle())
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
