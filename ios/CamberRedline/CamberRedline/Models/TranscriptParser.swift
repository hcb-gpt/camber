import Foundation

// MARK: - SpeakerTurn

struct SpeakerTurn: Identifiable {
    let id: UUID
    let speaker: String
    let text: String
    /// True when this speaker is on the owner side (right-aligned blue bubble).
    let isOwnerSide: Bool

    /// True when this turn's speaker matches the previous turn's speaker (for UI grouping).
    var isConsecutiveWithPrevious: Bool = false
}

// MARK: - TranscriptParser

enum TranscriptParser {

    /// Name fragments (lowercased) that identify the owner side (Zack / Chad / HCB).
    private static let ownerSideFragments: [String] = [
        "zack", "zach", "chad", "hcb",
    ]

    // MARK: - Public API

    /// Parse a `raw_transcript` string into an array of `SpeakerTurn` values.
    ///
    /// Expected format: newline-delimited lines of `"Speaker Name: utterance text"`.
    /// Consecutive turns from the same speaker are merged into one bubble.
    ///
    /// - Parameters:
    ///   - transcript: The raw transcript text returned by the edge function.
    ///   - contactName: Unused; kept for call-site compatibility.
    /// - Returns: Merged speaker turns with `isOwnerSide` and `isConsecutiveWithPrevious` set.
    static func parse(_ transcript: String, contactName: String? = nil) -> [SpeakerTurn] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Split into lines and parse each "Speaker: text" line.
        var rawTurns: [(speaker: String, text: String)] = []

        for line in trimmed.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            // Find the first colon to split speaker from text.
            if let colonIdx = trimmedLine.firstIndex(of: ":") {
                let speaker = String(trimmedLine[trimmedLine.startIndex..<colonIdx])
                    .trimmingCharacters(in: .whitespaces)
                let text = String(trimmedLine[trimmedLine.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)

                // Skip lines where the speaker is empty or the text is empty.
                guard !speaker.isEmpty, !text.isEmpty else { continue }
                rawTurns.append((speaker, text))
            } else {
                // No colon on this line — append to the previous speaker's text if possible.
                if !rawTurns.isEmpty {
                    rawTurns[rawTurns.count - 1].text += " " + trimmedLine
                } else {
                    rawTurns.append(("Unknown", trimmedLine))
                }
            }
        }

        guard !rawTurns.isEmpty else {
            return [
                SpeakerTurn(id: UUID(), speaker: "Unknown", text: trimmed, isOwnerSide: false),
            ]
        }

        // Merge consecutive turns from the same speaker.
        var merged: [(speaker: String, text: String)] = []
        for turn in rawTurns {
            if let last = merged.last, last.speaker == turn.speaker {
                merged[merged.count - 1].text += " " + turn.text
            } else {
                merged.append(turn)
            }
        }

        // Build SpeakerTurn array with consecutive grouping markers.
        var result: [SpeakerTurn] = []
        for (idx, entry) in merged.enumerated() {
            let ownerSide = isOwnerSide(speaker: entry.speaker)
            let consecutive = idx > 0 && merged[idx - 1].speaker == entry.speaker
            result.append(
                SpeakerTurn(
                    id: UUID(),
                    speaker: entry.speaker,
                    text: entry.text,
                    isOwnerSide: ownerSide,
                    isConsecutiveWithPrevious: consecutive
                )
            )
        }

        return result
    }

    // MARK: - Private helpers

    /// Returns true when the speaker name contains a known owner-side fragment.
    private static func isOwnerSide(speaker: String) -> Bool {
        let speakerLower = speaker.lowercased()
        return ownerSideFragments.contains(where: { speakerLower.contains($0) })
    }
}
