import SwiftUI

struct CallHeaderCard: View {
    let header: CallHeaderEntry
    var viewModel: ThreadViewModel

    private var isInbound: Bool {
        header.direction?.lowercased() == "inbound"
    }

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var formattedTime: String {
        guard let date = ThreadItem.callHeader(header).eventAtDate else {
            return ""
        }
        return Self.timeFormatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 10) {
                Image(systemName: "phone.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isInbound ? .green : .blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Phone Call")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)

                    HStack(spacing: 4) {
                        Text(formattedTime)
                        if let direction = header.direction {
                            Text("\u{00B7}")
                            Text(direction.capitalized)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(
                    systemName: isInbound
                        ? "arrow.down.left" : "arrow.up.right"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Summary (truncated to 2 lines)
            if let summary = header.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color(.systemGray))
                    .lineLimit(2)
            }

            // Claims section
            if !header.claims.isEmpty {
                Divider()
                    .overlay(Color(.systemGray4))

                Text("Claims (\(header.claims.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                ForEach(header.claims) { claim in
                    ClaimRow(claim: claim) { grade, correctionText in
                        Task {
                            await viewModel.gradeClaim(
                                claimId: claim.claimId,
                                grade: grade,
                                correctionText: correctionText
                            )
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemBackground))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    isInbound
                        ? Color(red: 0.19, green: 0.82, blue: 0.35)
                        : Color(red: 0, green: 0.48, blue: 1.0)
                )
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
