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
        case reviewQueueId = "review_queue_id"
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        interactionId = try container.decode(String.self, forKey: .interactionId)

        spanId = (try container.decodeIfPresent(String.self, forKey: .spanId))?.trimmedOrNil ?? ""

        // Some backends return `review_queue_id` instead of `id` (or omit `id` entirely).
        // For read-only degraded mode, fall back to `span_id` so cards still render.
        let idCandidate = (try? container.decode(String.self, forKey: .id))
            ?? (try? container.decode(String.self, forKey: .reviewQueueId))
            ?? spanId
        let trimmedId = idCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Missing id/review_queue_id/span_id"
            )
        }
        id = trimmedId

        transcriptSegment = (try container.decodeIfPresent(String.self, forKey: .transcriptSegment))?.trimmedOrNil ?? ""

        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        eventAt = try container.decodeIfPresent(String.self, forKey: .eventAt)
        confidence = Self.decodeLossyDouble(from: container, key: .confidence)
        aiGuessProjectId = (try container.decodeIfPresent(String.self, forKey: .aiGuessProjectId))?.trimmedOrNil
        contactName = try container.decodeIfPresent(String.self, forKey: .contactName)
        humanSummary = try container.decodeIfPresent(String.self, forKey: .humanSummary)
        fullTranscript = try container.decodeIfPresent(String.self, forKey: .fullTranscript)
        contextPayload = try? container.decodeIfPresent(ContextPayload.self, forKey: .contextPayload)
        reasons = Self.decodeLossyStringArray(from: container, key: .reasons)
        reasonCodes = Self.decodeLossyStringArray(from: container, key: .reasonCodes)
        decision = try container.decodeIfPresent(String.self, forKey: .decision)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(spanId, forKey: .spanId)
        try container.encode(interactionId, forKey: .interactionId)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(eventAt, forKey: .eventAt)
        try container.encode(transcriptSegment, forKey: .transcriptSegment)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encodeIfPresent(aiGuessProjectId, forKey: .aiGuessProjectId)
        try container.encodeIfPresent(contactName, forKey: .contactName)
        try container.encodeIfPresent(humanSummary, forKey: .humanSummary)
        try container.encodeIfPresent(fullTranscript, forKey: .fullTranscript)
        try container.encodeIfPresent(contextPayload, forKey: .contextPayload)
        try container.encodeIfPresent(reasons, forKey: .reasons)
        try container.encodeIfPresent(reasonCodes, forKey: .reasonCodes)
        try container.encodeIfPresent(decision, forKey: .decision)
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

    private static func decodeLossyDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }

    private static func decodeLossyStringArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> [String]? {
        if let values = try? container.decodeIfPresent([String].self, forKey: key) {
            return values
        }
        if let maybeSingle = try? container.decodeIfPresent(String.self, forKey: key),
           let single = maybeSingle.trimmedOrNil
        {
            return [single]
        }
        return nil
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
    let droppedItemCount: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case items
        case projects
        case totalPending = "total_pending"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        projects = try container.decodeIfPresent([ReviewProject].self, forKey: .projects) ?? []
        totalPending = try container.decodeIfPresent(Int.self, forKey: .totalPending) ?? 0

        let rawItems = try container.decodeIfPresent([LossyReviewItem].self, forKey: .items) ?? []
        items = rawItems.compactMap(\.item)
        droppedItemCount = rawItems.count - items.count
    }
}

private struct LossyReviewItem: Decodable {
    let item: ReviewItem?

    init(from decoder: Decoder) throws {
        item = try? ReviewItem(from: decoder)
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
