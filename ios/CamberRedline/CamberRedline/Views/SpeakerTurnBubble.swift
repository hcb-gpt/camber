import SwiftUI

struct SpeakerTurnBubble: View {
    let turn: SpeakerTurn
    var showSpeakerLabel: Bool = true

    // Owner side: #007AFF (iOS blue). Other side: #2C2C2E (dark gray).
    private var bubbleColor: Color {
        turn.isOwnerSide
            ? Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255)
            : Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
    }

    // Owner side: bottom-trailing tail (4 px). Other side: bottom-leading tail (4 px).
    private var bubbleShape: UnevenRoundedRectangle {
        if turn.isOwnerSide {
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
        HStack(alignment: .bottom, spacing: 0) {
            if turn.isOwnerSide { Spacer(minLength: 60) }

            VStack(alignment: turn.isOwnerSide ? .trailing : .leading, spacing: 2) {
                if showSpeakerLabel && !turn.isConsecutiveWithPrevious {
                    Text(turn.speaker)
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.55))
                        .padding(.horizontal, 4)
                }

                Text(turn.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .clipShape(bubbleShape)
            }

            if !turn.isOwnerSide { Spacer(minLength: 60) }
        }
    }
}
