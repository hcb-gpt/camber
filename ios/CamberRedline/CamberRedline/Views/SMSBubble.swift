import SwiftUI

struct SMSBubble: View {
    let entry: SMSEntry
    var showTimestamp: Bool = true
    var senderName: String? = nil

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

                Text(entry.content ?? "")
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .clipShape(bubbleShape)

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
}
