import SwiftUI

struct SMSBubble: View {
    let entry: SMSEntry

    private var isOutbound: Bool {
        entry.direction?.lowercased() == "outbound"
    }

    private var formattedTime: String {
        guard let date = ThreadItem.sms(entry).eventAtDate else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var bubbleColor: Color {
        isOutbound ? Color(red: 0, green: 0.478, blue: 1) : Color(UIColor.secondarySystemBackground)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        if isOutbound {
            UnevenRoundedRectangle(
                topLeadingRadius: 16,
                bottomLeadingRadius: 16,
                bottomTrailingRadius: 4,
                topTrailingRadius: 16
            )
        } else {
            UnevenRoundedRectangle(
                topLeadingRadius: 16,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: 16,
                topTrailingRadius: 16
            )
        }
    }

    var body: some View {
        HStack {
            if isOutbound { Spacer(minLength: UIScreen.main.bounds.width * 0.25) }

            VStack(alignment: isOutbound ? .trailing : .leading, spacing: 2) {
                Text(entry.content ?? "")
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .clipShape(bubbleShape)

                Text(formattedTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if !isOutbound { Spacer(minLength: UIScreen.main.bounds.width * 0.25) }
        }
    }
}
