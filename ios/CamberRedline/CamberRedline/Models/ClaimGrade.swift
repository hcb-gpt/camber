import Foundation

// MARK: - GradeType

enum GradeType: String, CaseIterable {
    case confirm
    case reject
    case correct
}

// MARK: - NewGrade

struct NewGrade: Encodable {
    let claimId: UUID
    let grade: String
    let correctionText: String?
    let gradedBy: String

    enum CodingKeys: String, CodingKey {
        case claimId = "claim_id"
        case grade
        case correctionText = "correction_text"
        case gradedBy = "graded_by"
    }
}
