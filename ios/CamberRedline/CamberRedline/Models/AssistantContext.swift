import Foundation

struct AssistantContextPacket: Decodable {
    let ok: Bool
    let generatedAt: String?
    let functionVersion: String?
    let pipelineHealth: [PipelineCapability]
    let topProjects: [ProjectSnapshot]
    let whoNeedsYou: [PeopleSignal]
    let reviewPressure: ReviewPressure?
    let recentActivity: RecentActivity?
    let ms: Int?

    enum CodingKeys: String, CodingKey {
        case ok
        case generatedAt = "generated_at"
        case functionVersion = "function_version"
        case pipelineHealth = "pipeline_health"
        case topProjects = "top_projects"
        case whoNeedsYou = "who_needs_you"
        case reviewPressure = "review_pressure"
        case recentActivity = "recent_activity"
        case ms
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
    let activeJournalClaims: Int?
    let openLoops: Int?
    let pendingReviews: Int?
    let strikingSignalCount: Int?
    let riskFlag: String?

    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case projectName = "project_name"
        case phase
        case interactions7d = "interactions_7d"
        case activeJournalClaims = "active_journal_claims"
        case openLoops = "open_loops"
        case pendingReviews = "pending_reviews"
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
