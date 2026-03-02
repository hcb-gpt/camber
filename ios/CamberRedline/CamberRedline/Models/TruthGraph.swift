import Foundation

struct TruthGraphHydration: Decodable {
    let callsRaw: Bool
    let interactions: Bool
    let conversationSpans: Bool
    let evidenceEvents: Bool
    let spanAttributions: Bool
    let journalClaims: Bool
    let reviewQueue: Bool

    enum CodingKeys: String, CodingKey {
        case callsRaw = "calls_raw"
        case interactions
        case conversationSpans = "conversation_spans"
        case evidenceEvents = "evidence_events"
        case spanAttributions = "span_attributions"
        case journalClaims = "journal_claims"
        case reviewQueue = "review_queue"
    }
}

struct TruthGraphSuggestedRepair: Decodable, Identifiable, Hashable {
    let action: String
    let label: String
    let idempotencyKey: String

    var id: String { idempotencyKey }

    enum CodingKeys: String, CodingKey {
        case action
        case label
        case idempotencyKey = "idempotency_key"
    }
}

struct TruthGraphResponse: Decodable {
    let ok: Bool
    let interactionId: String
    let hydration: TruthGraphHydration
    let lane: String
    let suggestedRepairs: [TruthGraphSuggestedRepair]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case interactionId = "interaction_id"
        case hydration
        case lane
        case suggestedRepairs = "suggested_repairs"
        case warnings
    }
}

struct TruthGraphRepairResponse: Decodable {
    let ok: Bool
    let requestId: String?
    let status: String?
    let idempotentReplay: Bool?
    let errorCode: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case requestId = "request_id"
        case status
        case idempotentReplay = "idempotent_replay"
        case errorCode = "error_code"
        case error
    }
}

