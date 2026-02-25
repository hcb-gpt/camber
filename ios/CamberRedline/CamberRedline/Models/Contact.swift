import Foundation

struct Contact: Codable, Identifiable, Hashable {
    let contactId: UUID
    let name: String
    let phone: String
    let callCount: Int
    let smsCount: Int
    let lastActivity: String?

    var id: UUID { contactId }

    enum CodingKeys: String, CodingKey {
        case contactId = "contact_id"
        case name
        case phone
        case callCount = "call_count"
        case smsCount = "sms_count"
        case lastActivity = "last_activity"
    }
}
