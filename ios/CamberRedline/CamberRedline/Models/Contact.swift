import Foundation

struct Contact: Codable, Identifiable, Hashable {
    let contactId: UUID
    let contactKey: String
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
        case contactKey = "contact_key"
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

        // Tolerant decode: accept UUID, UUID-string, or null for contact_id.
        // If null/missing, fall back to a deterministic UUID from contact_key.
        if let uuid = try? container.decode(UUID.self, forKey: .contactId) {
            contactId = uuid
        } else if let uuidString = try? container.decode(String.self, forKey: .contactId),
                  let uuid = UUID(uuidString: uuidString) {
            contactId = uuid
        } else {
            // Generate a deterministic UUID from contact_key or name so the row is still usable.
            let fallbackKey = (try? container.decodeIfPresent(String.self, forKey: .contactKey))
                ?? (try? container.decode(String.self, forKey: .name))
                ?? UUID().uuidString
            contactId = Contact.deterministicUUID(from: fallbackKey)
            #if DEBUG
                print("[Contact] contact_id was null/invalid; synthesized UUID from key: \(fallbackKey)")
            #endif
        }

        contactKey = try container.decodeIfPresent(String.self, forKey: .contactKey)
            ?? contactId.uuidString
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

    /// Generate a deterministic UUID from a string key (simple hash-based approach).
    private static func deterministicUUID(from key: String) -> UUID {
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        let bytes = withUnsafeBytes(of: hash.bigEndian) { Array($0) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let padded = (hex + "00000000000000000000000000000000").prefix(32)
        let s = padded
        let uuidString = "\(s.prefix(8))-\(s.dropFirst(8).prefix(4))-\(s.dropFirst(12).prefix(4))-\(s.dropFirst(16).prefix(4))-\(s.dropFirst(20).prefix(12))"
        return UUID(uuidString: String(uuidString)) ?? UUID()
    }
}
