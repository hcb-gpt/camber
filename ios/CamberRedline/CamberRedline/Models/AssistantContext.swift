import Foundation

struct AssistantContextPacket: Decodable {
    let ok: Bool
    let requestId: String?
    let generatedAt: String?
    let functionVersion: String?
    let contractVersion: String?
    let metricContract: MetricContract?
    let pipelineHealth: [PipelineCapability]
    let topProjects: [ProjectSnapshot]
    let whoNeedsYou: [PeopleSignal]
    let reviewPressure: ReviewPressure?
    let recentActivity: RecentActivity?
    let ms: Int?

    enum CodingKeys: String, CodingKey {
        case ok
        case requestId = "request_id"
        case generatedAt = "generated_at"
        case functionVersion = "function_version"
        case contractVersion = "contract_version"
        case metricContract = "metric_contract"
        case pipelineHealth = "pipeline_health"
        case topProjects = "top_projects"
        case whoNeedsYou = "who_needs_you"
        case reviewPressure = "review_pressure"
        case recentActivity = "recent_activity"
        case ms
    }
}

struct MetricContract: Decodable {
    let version: String?
    let topProjects: TopProjectsMetricContract?

    enum CodingKeys: String, CodingKey {
        case version
        case topProjects = "top_projects"
    }
}

struct TopProjectsMetricContract: Decodable {
    let explicitMetricFields: [String]?
    let preferredDisplayFields7d: [String]?
    let removedAmbiguousAliases: [String]?

    enum CodingKeys: String, CodingKey {
        case explicitMetricFields = "explicit_metric_fields"
        case preferredDisplayFields7d = "preferred_display_fields_7d"
        case removedAmbiguousAliases = "removed_ambiguous_aliases"
    }
}

struct PipelineCapability: Decodable, Identifiable {
    var id: String { capability }
    let capability: String
    let total: Int?
    let lastAt: String?
    let hoursStale: String?

    enum CodingKeys: String, CodingKey {
        case capability, total
        case lastAt = "last_at"
        case hoursStale = "hours_stale"
    }
}

struct ProjectSnapshot: Decodable, Identifiable {
    var id: String { projectId }
    let projectId: String
    let projectName: String
    let phase: String?
    let interactions7d: Int?
    let activeJournalClaimsTotal: Int?
    let activeJournalClaims7d: Int?
    let openLoopsTotal: Int?
    let openLoops7d: Int?
    let pendingReviewsSpanTotal: Int?
    let pendingReviewsQueueTotal: Int?
    let pendingReviewsQueue7d: Int?
    let strikingSignalCount: Int?
    let riskFlag: String?

    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case projectName = "project_name"
        case phase
        case interactions7d = "interactions_7d"
        case activeJournalClaimsTotal = "active_journal_claims_total"
        case activeJournalClaims7d = "active_journal_claims_7d"
        case openLoopsTotal = "open_loops_total"
        case openLoops7d = "open_loops_7d"
        case pendingReviewsSpanTotal = "pending_reviews_span_total"
        case pendingReviewsQueueTotal = "pending_reviews_queue_total"
        case pendingReviewsQueue7d = "pending_reviews_queue_7d"
        case strikingSignalCount = "striking_signal_count"
        case riskFlag = "risk_flag"
    }
}

struct PeopleSignal: Decodable, Identifiable {
    var id: String { "\(project)-\(category)-\(hoursAgo)" }
    let category: String
    let project: String
    let detail: String
    let speaker: String?
    let hoursAgo: String

    enum CodingKeys: String, CodingKey {
        case category, project, detail, speaker
        case hoursAgo = "hours_ago"
    }
}

struct ReviewPressure: Decodable {
    // Flexible — the view's shape may vary. Accept any fields.
    let pendingCount: Int?
    let resolvedCount: Int?

    enum CodingKeys: String, CodingKey {
        case pendingCount = "pending_count"
        case resolvedCount = "resolved_count"
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        pendingCount = try? container?.decodeIfPresent(Int.self, forKey: .pendingCount)
        resolvedCount = try? container?.decodeIfPresent(Int.self, forKey: .resolvedCount)
    }
}

struct RecentActivity: Decodable {
    let calls24h: Int
    let latestCalls: [RecentCall]

    enum CodingKeys: String, CodingKey {
        case calls24h = "calls_24h"
        case latestCalls = "latest_calls"
    }
}

struct RecentCall: Decodable, Identifiable {
    let id: String
    let otherPartyName: String?
    let channel: String?
    let eventAtUtc: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case id
        case otherPartyName = "other_party_name"
        case channel
        case eventAtUtc = "event_at_utc"
        case summary
    }
}
