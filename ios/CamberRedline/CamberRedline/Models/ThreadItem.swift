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
            return "sms-\(entry.smsId.uuidString)"
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
    let eventAt: String
    let direction: String?
    let summary: String?
    let transcript: String?
    let spans: [SpanEntry]
    let claims: [ClaimEntry]?

    enum CodingKeys: String, CodingKey {
        case interactionId = "interaction_id"
        case eventAt = "event_at"
        case direction
        case summary
        case transcript
        case spans
        case claims
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
    let direction: String?
    let summary: String?
    let claims: [ClaimEntry]
}

// MARK: - SpanEntry

struct SpanEntry: Codable, Identifiable {
    let spanId: UUID
    let spanIndex: Int
    let transcriptSegment: String?
    let claims: [ClaimEntry]

    var id: UUID { spanId }

    enum CodingKeys: String, CodingKey {
        case spanId = "span_id"
        case spanIndex = "span_index"
        case transcriptSegment = "transcript_segment"
        case claims
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
    let smsId: UUID
    let eventAt: String
    let direction: String?
    let content: String?

    var id: UUID { smsId }

    enum CodingKeys: String, CodingKey {
        case smsId = "sms_id"
        case eventAt = "event_at"
        case direction
        case content
    }
}
