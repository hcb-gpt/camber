import SwiftUI

struct SpeakerTurnBubble: View {
    let turn: SpeakerTurn
    var showSpeakerLabel: Bool = true

    private var bubbleColor: Color {
        turn.isOurSide
            ? Color(red: 0, green: 0.478, blue: 1)
            : Color(UIColor.tertiarySystemBackground)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        if turn.isOurSide {
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
            if turn.isOurSide { Spacer(minLength: 60) }

            VStack(alignment: turn.isOurSide ? .trailing : .leading, spacing: 2) {
                if showSpeakerLabel {
                    Text(turn.speaker)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                Text(turn.text)
                    .font(.body)
                    .foregroundStyle(turn.isOurSide ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .clipShape(bubbleShape)
            }

            if !turn.isOurSide { Spacer(minLength: 60) }
        }
    }
}
