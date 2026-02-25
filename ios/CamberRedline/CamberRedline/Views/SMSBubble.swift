import SwiftUI

struct SMSBubble: View {
    let entry: SMSEntry
    var showTimestamp: Bool = true

    private var isOutbound: Bool {
        entry.direction?.lowercased() == "outbound"
    }

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var formattedTime: String {
        guard let date = ThreadItem.sms(entry).eventAtDate else { return "" }
        return Self.timeFormatter.string(from: date)
    }

    private var bubbleColor: Color {
        isOutbound ? Color(red: 0, green: 0.478, blue: 1) : Color(UIColor.tertiarySystemBackground)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        if isOutbound {
            UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 4,
                topTrailingRadius: 18
            )
        } else {
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
                Text(entry.content ?? "")
                    .font(.body)
                    .foregroundStyle(isOutbound ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .clipShape(bubbleShape)

                if showTimestamp {
                    Text(formattedTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }

            if !isOutbound { Spacer(minLength: 60) }
        }
    }
}
