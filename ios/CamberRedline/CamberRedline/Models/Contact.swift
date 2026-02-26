import Foundation

struct Contact: Codable, Identifiable, Hashable {
    let contactId: UUID
    let name: String
    /// Phone number. Not returned by the v2 contacts endpoint; optional with nil default.
    let phone: String?
    let callCount: Int
    let smsCount: Int
    /// Not returned by the v2 contacts endpoint; optional with 0 default.
    let claimCount: Int
    /// Not returned by the v2 contacts endpoint; optional with 0 default.
    let ungradedCount: Int
    let lastActivity: String?
    let lastSnippet: String?
    let lastDirection: String?
    let lastInteractionType: String?

    var id: UUID { contactId }

    enum CodingKeys: String, CodingKey {
        case contactId = "contact_id"
        case name = "name"
        case phone = "phone"
        case callCount = "call_count"
        case smsCount = "sms_count"
        case claimCount = "claim_count"
        case ungradedCount = "ungraded_count"
        case lastActivity = "last_activity"
        case lastSnippet = "last_summary"
        case lastDirection = "last_direction"
        case lastInteractionType = "last_interaction_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contactId = try container.decode(UUID.self, forKey: .contactId)
        name = try container.decode(String.self, forKey: .name)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        callCount = try container.decodeIfPresent(Int.self, forKey: .callCount) ?? 0
        smsCount = try container.decodeIfPresent(Int.self, forKey: .smsCount) ?? 0
        claimCount = try container.decodeIfPresent(Int.self, forKey: .claimCount) ?? 0
        ungradedCount = try container.decodeIfPresent(Int.self, forKey: .ungradedCount) ?? 0
        lastActivity = try container.decodeIfPresent(String.self, forKey: .lastActivity)
        lastSnippet = try container.decodeIfPresent(String.self, forKey: .lastSnippet)
        lastDirection = try container.decodeIfPresent(String.self, forKey: .lastDirection)
        lastInteractionType = try container.decodeIfPresent(String.self, forKey: .lastInteractionType)
    }
}
