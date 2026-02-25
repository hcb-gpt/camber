import SwiftUI

struct CallSummaryCard: View {
    let entry: CallEntry
    var viewModel: ThreadViewModel

    @State private var showTranscript = false

    private var isInbound: Bool {
        entry.direction?.lowercased() == "inbound"
    }

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var formattedTime: String {
        guard let date = ThreadItem.call(entry).eventAtDate else { return "" }
        return Self.timeFormatter.string(from: date)
    }

    private var allClaims: [ClaimEntry] {
        entry.spans.flatMap(\.claims)
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
                        if let direction = entry.direction {
                            Text("·")
                            Text(direction.capitalized)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isInbound ? "arrow.down.left" : "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Summary
            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color(.systemGray))
                    .lineLimit(3)
            }

            // Claims section
            if !allClaims.isEmpty {
                Divider()
                    .overlay(Color(.systemGray4))

                Text("Claims (\(allClaims.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                ForEach(allClaims) { claim in
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

            // Transcript disclosure
            if hasTranscript {
                Divider()
                    .overlay(Color(.systemGray4))

                DisclosureGroup(isExpanded: $showTranscript) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entry.spans) { span in
                            if let text = span.transcriptSegment, !text.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Span \(span.spanIndex)")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.secondary)

                                    Text(text)
                                        .font(.caption)
                                        .foregroundStyle(Color(.systemGray))
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Show Transcript")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemBackground))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isInbound ? Color(red: 0.19, green: 0.82, blue: 0.35) : Color(red: 0, green: 0.48, blue: 1.0))
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var hasTranscript: Bool {
        entry.spans.contains { span in
            if let text = span.transcriptSegment, !text.isEmpty {
                return true
            }
            return false
        }
    }
}
