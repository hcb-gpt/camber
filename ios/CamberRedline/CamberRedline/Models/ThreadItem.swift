import Foundation

// MARK: - ThreadItem

enum ThreadItem: Identifiable {
    case call(CallEntry)
    case sms(SMSEntry)
    case speakerTurn(SpeakerTurn)
    case callHeader(CallHeaderEntry)

    var id: String {
        switch self {
        case .call(let entry):
            return "call-\(entry.interactionId)"
        case .sms(let entry):
            return "sms-\(entry.messageId)"
        case .speakerTurn(let turn):
            return "turn-\(turn.id.uuidString)"
        case .callHeader(let header):
            return "header-\(header.interactionId)"
        }
    }

    var eventAtDate: Date? {
        let raw: String
        switch self {
        case .call(let entry):
            raw = entry.eventAt
        case .sms(let entry):
            raw = entry.eventAt
        case .speakerTurn:
            return nil
        case .callHeader(let header):
            raw = header.eventAt
        }
        return Self.parseISO8601(raw)
    }

    nonisolated(unsafe) private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO8601(_ string: String) -> Date? {
        if let date = isoFormatterFractional.date(from: string) {
            return date
        }
        return isoFormatterBasic.date(from: string)
    }
}

// MARK: - CallEntry

struct CallEntry: Codable {
    let interactionId: String
    /// ISO-8601 timestamp. v2 API key is `event_at`.
    let eventAt: String
    let contactName: String?
    let direction: String?
    let channel: String?
    /// Human-readable summary. v2 API key is `human_summary`.
    let summary: String?
    /// Full raw transcript. v2 API key is `raw_transcript`.
    let rawTranscript: String?
    /// Participant names/labels reported by the API.
    let participants: [String]
    let spans: [SpanEntry]
    let pendingAttributionCount: Int
    let claims: [ClaimEntry]?

    enum CodingKeys: String, CodingKey {
        case interactionId = "interaction_id"
        case eventAt = "event_at"
        case contactName = "contact_name"
        case direction
        case channel
        case summary
        case rawTranscript = "raw_transcript"
        case participants
        case spans
        case pendingAttributionCount = "pending_attribution_count"
        case claims
    }

    init(
        interactionId: String,
        eventAt: String,
        contactName: String? = nil,
        direction: String? = nil,
        channel: String? = nil,
        summary: String? = nil,
        rawTranscript: String? = nil,
        participants: [String] = [],
        spans: [SpanEntry] = [],
        pendingAttributionCount: Int = 0,
        claims: [ClaimEntry]? = nil
    ) {
        self.interactionId = interactionId
        self.eventAt = eventAt
        self.contactName = contactName
        self.direction = direction
        self.channel = channel
        self.summary = summary
        self.rawTranscript = rawTranscript
        self.participants = participants
        self.spans = spans
        self.pendingAttributionCount = pendingAttributionCount
        self.claims = claims
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interactionId = try container.decode(String.self, forKey: .interactionId)
        eventAt = try container.decode(String.self, forKey: .eventAt)
        contactName = try container.decodeIfPresent(String.self, forKey: .contactName)
        direction = try container.decodeIfPresent(String.self, forKey: .direction)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        rawTranscript = try container.decodeIfPresent(String.self, forKey: .rawTranscript)
        participants = try container.decodeIfPresent([String].self, forKey: .participants) ?? []
        spans = try container.decodeIfPresent([SpanEntry].self, forKey: .spans) ?? []
        pendingAttributionCount = try container.decodeIfPresent(Int.self, forKey: .pendingAttributionCount) ?? 0
        claims = try container.decodeIfPresent([ClaimEntry].self, forKey: .claims)
    }

    /// All claims — prefers top-level claims (from call_id path), falls back to span claims.
    var allClaims: [ClaimEntry] {
        if let topLevel = claims, !topLevel.isEmpty {
            return topLevel
        }
        return spans.flatMap(\.claims)
    }
}

// MARK: - CallHeaderEntry

struct CallHeaderEntry {
    let interactionId: String
    let eventAt: String
    let contactName: String?
    let direction: String?
    let channel: String?
    let summary: String?
    let claims: [ClaimEntry]
    let spans: [SpanEntry]
    let pendingAttributionCount: Int
}

// MARK: - SpanEntry

struct SpanEntry: Codable, Identifiable {
    let spanId: UUID
    let spanIndex: Int
    let transcriptSegment: String?
    let reviewQueueId: String?
    let needsAttribution: Bool
    let projectId: String?
    let projectName: String?
    let confidence: Double?
    let claims: [ClaimEntry]

    var id: UUID { spanId }

    enum CodingKeys: String, CodingKey {
        case spanId = "span_id"
        case spanIndex = "span_index"
        case transcriptSegment = "transcript_segment"
        case reviewQueueId = "review_queue_id"
        case needsAttribution = "needs_attribution"
        case projectId = "project_id"
        case projectName = "project_name"
        case confidence
        case claims
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spanId = try container.decode(UUID.self, forKey: .spanId)
        spanIndex = try container.decode(Int.self, forKey: .spanIndex)
        transcriptSegment = try container.decodeIfPresent(String.self, forKey: .transcriptSegment)
        reviewQueueId = try container.decodeIfPresent(String.self, forKey: .reviewQueueId)
        needsAttribution = try container.decodeIfPresent(Bool.self, forKey: .needsAttribution) ?? false
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        claims = try container.decodeIfPresent([ClaimEntry].self, forKey: .claims) ?? []
    }
}

// MARK: - ClaimEntry

struct ClaimEntry: Codable, Identifiable {
    let claimId: UUID
    let claimType: String?
    let claimText: String
    let grade: String?
    let correctionText: String?
    let gradedBy: String?

    var id: UUID { claimId }

    enum CodingKeys: String, CodingKey {
        case claimId = "claim_id"
        case claimType = "claim_type"
        case claimText = "claim_text"
        case grade
        case correctionText = "correction_text"
        case gradedBy = "graded_by"
    }
}

// MARK: - SMSEntry

struct SMSEntry: Codable, Identifiable {
    /// v2 API returns `message_id` as a String (not UUID).
    let messageId: String
    /// ISO-8601 timestamp. v2 API key is `sent_at`.
    let sentAt: String
    let direction: String?
    let content: String?
    /// Display name of the sender. v2 API key is `sender_name`.
    let senderName: String?
    let reviewQueueId: String?
    let needsAttribution: Bool

    /// Stable `Identifiable` id derived from the message_id string.
    var id: String { messageId }

    /// Convenience alias so `ThreadItem.eventAtDate` can use a uniform property name.
    var eventAt: String { sentAt }

    enum CodingKeys: String, CodingKey {
        case messageId = "sms_id"
        case sentAt = "event_at"
        case direction
        case content
        case senderName = "sender_name"
        case reviewQueueId = "review_queue_id"
        case needsAttribution = "needs_attribution"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decode(String.self, forKey: .messageId)
        sentAt = try container.decode(String.self, forKey: .sentAt)
        direction = try container.decodeIfPresent(String.self, forKey: .direction)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName)
        reviewQueueId = try container.decodeIfPresent(String.self, forKey: .reviewQueueId)
        needsAttribution = try container.decodeIfPresent(Bool.self, forKey: .needsAttribution) ?? false
    }
}
