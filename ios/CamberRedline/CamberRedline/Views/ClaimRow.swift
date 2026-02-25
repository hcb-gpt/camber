import SwiftUI

struct ClaimRow: View {
    let claim: ClaimEntry
    let onGrade: (GradeType, String?) -> Void

    @State private var showCorrectionSheet = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            GradeIndicator(grade: claim.grade)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                if let claimType = claim.claimType, !claimType.isEmpty {
                    Text(claimType)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.systemGray3))
                        .clipShape(Capsule())
                }

                Text(claim.claimText)
                    .font(.subheadline)
                    .foregroundStyle(.white)

                // Show correction text if graded as correct
                if claim.grade == GradeType.correct.rawValue,
                   let correction = claim.correctionText, !correction.isEmpty
                {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.caption2)
                        Text(correction)
                            .font(.caption)
                    }
                    .foregroundStyle(.orange)
                }

                // Show graded-by if available
                if let gradedBy = claim.gradedBy, !gradedBy.isEmpty {
                    Text("Graded by \(gradedBy)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Dark card background (#1C1C1E) with horizontal insets for legibility
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.110, green: 0.110, blue: 0.118)) // #1C1C1E
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onGrade(.confirm, nil)
            } label: {
                Label("Confirm", systemImage: "checkmark.circle")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button {
                onGrade(.reject, nil)
            } label: {
                Label("Reject", systemImage: "xmark.circle")
            }
            .tint(.red)

            Button {
                showCorrectionSheet = true
            } label: {
                Label("Correct", systemImage: "pencil.circle")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                onGrade(.confirm, nil)
            } label: {
                Label("Confirm", systemImage: "checkmark.circle")
            }

            Button(role: .destructive) {
                onGrade(.reject, nil)
            } label: {
                Label("Reject", systemImage: "xmark.circle")
            }

            Button {
                showCorrectionSheet = true
            } label: {
                Label("Correct", systemImage: "pencil.circle")
            }
        }
        .sheet(isPresented: $showCorrectionSheet) {
            CorrectionSheet { correctionText in
                onGrade(.correct, correctionText)
            }
        }
    }
}
