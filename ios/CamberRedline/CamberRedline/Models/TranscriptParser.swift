import Foundation

// MARK: - SpeakerTurn

struct SpeakerTurn: Identifiable {
    let id: UUID
    let speaker: String
    let text: String
    let isOurSide: Bool

    /// True when this turn's speaker matches the previous turn's speaker (for UI grouping).
    var isConsecutiveWithPrevious: Bool = false
}

// MARK: - TranscriptParser

enum TranscriptParser {

    /// Known names that represent "our side" (Zack / Chad / HCB).
    private static let ourSideNames: Set<String> = [
        "zack sittler", "zachary sittler", "zack", "zach",
        "chad", "chad barlow", "hcb",
    ]

    // Matches an optional `[HH:MM]` timestamp, then a speaker label, then `: `.
    // Speaker labels: named ("Malcolm Hetzer"), generic ("SPEAKER_0"), or single word ("Zack").
    // Anchored to start-of-line (MULTILINE flag).
    //
    // Groups:
    //   1 — optional timestamp bracket, e.g. "[21:12] "
    //   2 — speaker name
    private static let speakerPattern: NSRegularExpression = {
        // Matches named speakers ("Malcolm Hetzer"), generic ("SPEAKER_0"),
        // and phone numbers ("+14048249717"). Anchored to start-of-line.
        // Groups: 1 = optional timestamp, 2 = speaker name/number
        let pattern = #"(?:^|\n)(\[[\d:]+\]\s*)?((?:[A-Za-z_][A-Za-z0-9_ ]*?)|(?:\+\d[\d() -]*)):\s"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    // MARK: - Public API

    /// Parse a transcript string into an array of `SpeakerTurn` values.
    ///
    /// - Parameters:
    ///   - transcript: The raw transcript text from the database.
    ///   - contactName: The name of the contact (used to determine left/right side).
    /// - Returns: An array of speaker turns, with `isConsecutiveWithPrevious` set for grouping.
    static func parse(_ transcript: String, contactName: String?) -> [SpeakerTurn] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = speakerPattern.matches(in: trimmed, options: [], range: nsRange)

        // No speaker labels found — return the entire transcript as a single turn.
        guard !matches.isEmpty else {
            return [
                SpeakerTurn(
                    id: UUID(),
                    speaker: "Unknown",
                    text: trimmed,
                    isOurSide: false
                ),
            ]
        }

        // Extract raw (speaker, textBody) pairs from regex matches.
        var rawTurns: [(speaker: String, text: String)] = []

        // If there is text before the first match, capture it as an "Unknown" turn.
        let firstMatchStart = Range(matches[0].range, in: trimmed)!.lowerBound
        if firstMatchStart > trimmed.startIndex {
            let prefix = String(trimmed[trimmed.startIndex..<firstMatchStart])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                rawTurns.append(("Unknown", prefix))
            }
        }

        for (idx, match) in matches.enumerated() {
            // Extract speaker name (group 2).
            guard let speakerRange = Range(match.range(at: 2), in: trimmed) else { continue }
            let speaker = String(trimmed[speakerRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Text runs from end of the full match to the start of the next match (or end of string).
            let matchEnd = Range(match.range, in: trimmed)!.upperBound
            let textEnd: String.Index
            if idx + 1 < matches.count {
                textEnd = Range(matches[idx + 1].range, in: trimmed)!.lowerBound
            } else {
                textEnd = trimmed.endIndex
            }

            let body = String(trimmed[matchEnd..<textEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            rawTurns.append((speaker, body))
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

        // Determine which speakers are "our side".
        let contactLower = contactName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Build SpeakerTurn array with consecutive grouping.
        var result: [SpeakerTurn] = []
        for (idx, entry) in merged.enumerated() {
            let isOur = isOurSide(speaker: entry.speaker, contactNameLower: contactLower)
            let consecutive = idx > 0 && merged[idx - 1].speaker == entry.speaker
            result.append(
                SpeakerTurn(
                    id: UUID(),
                    speaker: entry.speaker,
                    text: entry.text,
                    isOurSide: isOur,
                    isConsecutiveWithPrevious: consecutive
                )
            )
        }

        return result
    }

    // MARK: - Private helpers

    /// Decide whether a speaker name represents "our side" (HCB team).
    ///
    /// Only speakers explicitly in `ourSideNames` are treated as our side.
    /// Everyone else defaults to external (left-side / gray bubbles).
    private static func isOurSide(speaker: String, contactNameLower: String?) -> Bool {
        let speakerLower = speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Explicit our-side match (Zack, Chad, HCB).
        if ourSideNames.contains(speakerLower) {
            return true
        }

        // Everyone else is external.
        return false
    }
}
