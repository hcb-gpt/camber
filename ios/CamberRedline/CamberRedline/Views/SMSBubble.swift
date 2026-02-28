import SwiftUI

struct SMSBubble: View {
    let entry: SMSEntry
    var showTimestamp: Bool = true
    var senderName: String? = nil

    private var isOutbound: Bool {
        entry.direction?.lowercased() == "outbound"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var formattedTime: String {
        guard let date = ThreadItem.sms(entry).eventAtDate else { return "" }
        return Self.timeFormatter.string(from: date)
    }

    private enum Payload {
        case text(String)
        case image(URL)
        case attachmentUnavailable
    }

    private static let urlRegex = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"']+"#,
        options: [.caseInsensitive]
    )

    private var payload: Payload {
        let normalized = normalizedContent
        if let imageURL = Self.extractImageURL(from: normalized) {
            return .image(imageURL)
        }
        if !normalized.isEmpty {
            return .text(normalized)
        }
        return .attachmentUnavailable
    }

    private var normalizedContent: String {
        // Strip object-replacement glyphs that often represent attachment-only SMS payloads.
        let raw = entry.content ?? ""
        let cleaned = raw.replacingOccurrences(of: "\u{FFFC}", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractImageURL(from content: String) -> URL? {
        guard !content.isEmpty else { return nil }
        let candidates: [String]

        if let regex = urlRegex {
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            let matches = regex.matches(in: content, options: [], range: range)
            candidates = matches.compactMap { match in
                guard let matchRange = Range(match.range, in: content) else { return nil }
                return String(content[matchRange])
            }
        } else {
            candidates = [content]
        }

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)\"]'"))
            guard let url = URL(string: trimmed), Self.looksLikeImageURL(url) else { continue }
            return url
        }

        return nil
    }

    private static func looksLikeImageURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.contains("/service-message/medias/") {
            return true
        }
        let imageSuffixes = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif"]
        return imageSuffixes.contains(where: { path.hasSuffix($0) })
    }

    private func isExpiredSignedURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        guard
            let dateRaw = components.queryItems?.first(where: { $0.name.caseInsensitiveCompare("X-Amz-Date") == .orderedSame })?.value,
            let expiresRaw = components.queryItems?.first(where: { $0.name.caseInsensitiveCompare("X-Amz-Expires") == .orderedSame })?.value,
            let expiresSeconds = TimeInterval(expiresRaw)
        else {
            return false
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        guard let signedAt = formatter.date(from: dateRaw) else { return false }
        return Date() > signedAt.addingTimeInterval(expiresSeconds)
    }

    // #007AFF outbound (spec), #2C2C2E inbound (spec)
    private var bubbleColor: Color {
        isOutbound
            ? Color(red: 0, green: 0.478, blue: 1)           // #007AFF
            : Color(red: 0.173, green: 0.173, blue: 0.173)   // #2C2C2E
    }

    private var bubbleShape: UnevenRoundedRectangle {
        if isOutbound {
            // tail at bottom-trailing corner
            UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 4,
                topTrailingRadius: 18
            )
        } else {
            // tail at bottom-leading corner
            UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: 18,
                topTrailingRadius: 18
            )
        }
    }

    var body: some View {
        HStack {
            if isOutbound { Spacer(minLength: 60) }

            VStack(alignment: isOutbound ? .trailing : .leading, spacing: 2) {
                // Sender name label — #8E8E93, shown above inbound bubbles only
                if !isOutbound, let name = senderName, !name.isEmpty {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(Color(red: 0.557, green: 0.557, blue: 0.576)) // #8E8E93
                        .padding(.horizontal, 4)
                }

                bubbleContent

                if showTimestamp {
                    Text(formattedTime)
                        .font(.caption2)
                        .foregroundStyle(Color(.systemGray3))
                        .opacity(0.55)
                        .padding(.horizontal, 4)
                }
            }

            if !isOutbound { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch payload {
        case .text(let value):
            Text(value)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor)
                .clipShape(bubbleShape)

        case .image(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .tint(.white)
                        .frame(width: 220, height: 140)
                        .background(bubbleColor)
                        .clipShape(bubbleShape)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 240)
                        .background(bubbleColor)
                        .clipShape(bubbleShape)
                case .failure:
                    attachmentFallback(message: isExpiredSignedURL(url) ? "Image link expired" : "Image unavailable")
                @unknown default:
                    attachmentFallback(message: "Image unavailable")
                }
            }

        case .attachmentUnavailable:
            attachmentFallback(message: "Attachment unavailable")
        }
    }

    private func attachmentFallback(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.subheadline)
            Text(message)
                .font(.callout)
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(bubbleColor)
        .clipShape(bubbleShape)
    }
}
