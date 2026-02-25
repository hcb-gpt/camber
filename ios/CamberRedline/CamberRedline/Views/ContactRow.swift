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

            Image(systemName: "phone.fill")
                .font(.body)
                .foregroundStyle(Color(white: 0.35))
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
        if let summary = contact.lastSummary, !summary.isEmpty {
            return summary
        }
        let parts: [String] = [
            contact.callCount > 0 ? "\(contact.callCount) calls" : nil,
            contact.smsCount > 0 ? "\(contact.smsCount) messages" : nil,
        ].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    // MARK: - Relative Time

    private var relativeTimeString: String? {
        guard let lastActivity = contact.lastActivity else { return nil }
        guard let date = parseDate(lastActivity) else { return nil }
        return relativeString(from: date)
    }

    private func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }
        // Postgres format: "2026-02-23 18:36:12+00"
        let pg = DateFormatter()
        pg.dateFormat = "yyyy-MM-dd HH:mm:ssxx"
        pg.locale = Locale(identifier: "en_US_POSIX")
        return pg.date(from: string)
    }

    private func relativeString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3_600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3_600))h" }
        if interval < 604_800 { return "\(Int(interval / 86_400))d" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }
}
