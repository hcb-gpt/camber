import Foundation

// MARK: - SpeakerTurn

struct SpeakerTurn: Identifiable {
    let id: UUID
    let speaker: String
    let text: String
    /// True when this speaker is on the owner side (right-aligned blue bubble).
    let isOwnerSide: Bool
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
    /// - Returns: Merged speaker turns with owner-side metadata.
    static func parse(_ transcript: String, contactName: String? = nil) -> [SpeakerTurn] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // First attempt: parse inline speaker markers so single-line segments like
        // "Malcolm Hetzer: ... Zachary Sittler: ..." render as alternating bubbles.
        let inlineTurns = parseInlineSpeakerMarkers(from: trimmed)

        // Fallback: line-based parsing for transcripts already split by newline.
        var rawTurns = parseLineBasedTurns(from: trimmed)

        // Prefer inline parsing when it discovered clear speaker alternation.
        if inlineTurns.count >= 2 {
            rawTurns = inlineTurns
        } else if rawTurns.count <= 1, !inlineTurns.isEmpty {
            rawTurns = inlineTurns
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

        // Build SpeakerTurn array.
        var result: [SpeakerTurn] = []
        for entry in merged {
            let ownerSide = isOwnerSide(speaker: entry.speaker)
            result.append(
                SpeakerTurn(
                    id: UUID(),
                    speaker: entry.speaker,
                    text: entry.text,
                    isOwnerSide: ownerSide
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

    private static func parseLineBasedTurns(from transcript: String) -> [(speaker: String, text: String)] {
        var rawTurns: [(speaker: String, text: String)] = []

        for line in transcript.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            if let colonIdx = trimmedLine.firstIndex(of: ":") {
                let speaker = String(trimmedLine[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let text = String(trimmedLine[trimmedLine.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                guard !speaker.isEmpty, !text.isEmpty else { continue }
                rawTurns.append((speaker, text))
            } else if !rawTurns.isEmpty {
                rawTurns[rawTurns.count - 1].text += " " + trimmedLine
            } else {
                rawTurns.append(("Unknown", trimmedLine))
            }
        }

        return rawTurns
    }

    private static func parseInlineSpeakerMarkers(from transcript: String) -> [(speaker: String, text: String)] {
        let pattern = #"(?:^|\s)(?:\[(?:\d{1,2}:)?\d{1,2}:\d{2}\]\s*)?([A-Z][A-Za-z0-9.'-]*(?:\s+[A-Z][A-Za-z0-9.'-]*){0,3}):\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let fullRange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        let matches = regex.matches(in: transcript, options: [], range: fullRange)
        guard !matches.isEmpty else { return [] }

        var turns: [(speaker: String, text: String)] = []

        for index in matches.indices {
            let match = matches[index]
            let speakerRange = match.range(at: 1)
            guard
                let speakerSwiftRange = Range(speakerRange, in: transcript)
            else { continue }

            let speaker = String(transcript[speakerSwiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speaker.isEmpty else { continue }

            let contentStartLocation = match.range.location + match.range.length
            let contentEndLocation = (index + 1 < matches.count)
                ? matches[index + 1].range.location
                : fullRange.location + fullRange.length
            guard contentEndLocation > contentStartLocation else { continue }

            let contentRange = NSRange(location: contentStartLocation, length: contentEndLocation - contentStartLocation)
            guard let contentSwiftRange = Range(contentRange, in: transcript) else { continue }

            let text = String(transcript[contentSwiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            turns.append((speaker, text))
        }

        return turns
    }
}
