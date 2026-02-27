import Foundation

// MARK: - ReviewItem

struct ReviewItem: Codable, Identifiable {
    let id: String
    let spanId: String
    let interactionId: String
    let createdAt: String?
    let eventAt: String?
    let transcriptSegment: String
    let confidence: Double?
    let aiGuessProjectId: String?
    let contactName: String?
    let humanSummary: String?
    let fullTranscript: String?
    let contextPayload: ContextPayload?
    let reasons: [String]?
    let reasonCodes: [String]?
    let decision: String?

    enum CodingKeys: String, CodingKey {
        case id
        case spanId = "span_id"
        case interactionId = "interaction_id"
        case createdAt = "created_at"
        case eventAt = "event_at"
        case transcriptSegment = "transcript_segment"
        case confidence
        case aiGuessProjectId = "ai_guess_project_id"
        case contactName = "contact_name"
        case humanSummary = "human_summary"
        case fullTranscript = "full_transcript"
        case contextPayload = "context_payload"
        case reasons
        case reasonCodes = "reason_codes"
        case decision
    }

    var sortDate: Date {
        if let eventDate = parseISO8601(eventAt) {
            return eventDate
        }
        if let createdDate = parseISO8601(createdAt) {
            return createdDate
        }
        return .distantPast
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let basicFormatter = ISO8601DateFormatter()
        basicFormatter.formatOptions = [.withInternetDateTime]
        return basicFormatter.date(from: value)
    }
}

// MARK: - ContextPayload

struct ContextPayload: Codable {
    // The actual API returns a complex nested structure. We only extract fields we use.
    // Unknown fields are silently ignored by Swift's Codable.
    let projectHints: [String]?
    let speakerTurns: [String]?
    let keywords: [String]?
    let candidates: [Candidate]?
    let anchors: [Anchor]?
    let modelId: String?
    let promptVersion: String?
    let createdAtUtc: String?
    let transcriptSnippet: String?
    let spanId: String?
    let interactionId: String?

    enum CodingKeys: String, CodingKey {
        case projectHints = "project_hints"
        case speakerTurns = "speaker_turns"
        case keywords
        case candidates
        case anchors
        case modelId = "model_id"
        case promptVersion = "prompt_version"
        case createdAtUtc = "created_at_utc"
        case transcriptSnippet = "transcript_snippet"
        case spanId = "span_id"
        case interactionId = "interaction_id"
    }
}

// MARK: - Candidate (from context_payload)

struct Candidate: Codable {
    let name: String
    let projectId: String
    let evidenceTags: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case projectId = "project_id"
        case evidenceTags = "evidence_tags"
    }
}

// MARK: - Anchor (from context_payload)

struct Anchor: Codable {
    let text: String?
    let quote: String?
    let matchType: String?
    let candidateProjectId: String?

    enum CodingKeys: String, CodingKey {
        case text
        case quote
        case matchType = "match_type"
        case candidateProjectId = "candidate_project_id"
    }
}

// MARK: - ReviewQueue Response

struct ReviewQueueResponse: Decodable {
    let ok: Bool
    let items: [ReviewItem]
    let projects: [ReviewProject]
    let totalPending: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case items
        case projects
        case totalPending = "total_pending"
    }
}
