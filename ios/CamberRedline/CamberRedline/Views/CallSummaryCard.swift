import SwiftUI

// MARK: - Design tokens
private let cardBackground = Color(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0)
private let textPrimary    = Color.white
private let textSecondary  = Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
private let cardRadius: CGFloat = 16
private let summaryMaxChars = 200

struct CallSummaryCard: View {
    let entry: CallEntry
    var viewModel: ThreadViewModel

    @State private var expanded = false

    private var isInbound: Bool {
        entry.direction?.lowercased() == "inbound"
    }

    // MARK: - Formatters

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    nonisolated(unsafe) private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var eventDate: Date? {
        ThreadItem.call(entry).eventAtDate
    }

    private var formattedTime: String {
        guard let date = eventDate else { return "" }
        return Self.timeFormatter.string(from: date)
    }

    private var formattedDate: String {
        guard let date = eventDate else { return "" }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return Self.dateFormatter.string(from: date)
    }

    // MARK: - Derived content

    /// First non-empty line of human_summary, falling back to "Phone Call".
    private var callTitle: String {
        guard let summary = entry.summary, !summary.isEmpty else { return "Phone Call" }
        let firstLine = summary
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? "Phone Call"
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    /// Participants label built from the participants array, falling back to contactName.
    private var participantsLabel: String {
        if !entry.participants.isEmpty {
            let others = entry.participants.filter {
                !$0.lowercased().contains("zack")
            }
            let otherName = others.first ?? entry.participants.first ?? ""
            if !otherName.isEmpty {
                return "👤 Zack ↔ \(otherName)"
            }
        }
        if let contact = entry.contactName, !contact.isEmpty {
            return "👤 Zack ↔ \(contact)"
        }
        return "👤 Zack"
    }

    /// Truncated summary body (200 chars max), excluding the first line (used as title).
    private var summaryBody: String? {
        guard let full = entry.summary, !full.isEmpty else { return nil }
        // Drop the first line (already shown as title), join the rest.
        let lines = full.components(separatedBy: .newlines)
        let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        if rest.count <= summaryMaxChars { return rest }
        let truncIndex = rest.index(rest.startIndex, offsetBy: summaryMaxChars)
        return String(rest[..<truncIndex]) + "…"
    }

    private var allClaims: [ClaimEntry] { entry.allClaims }

    private var hasTranscript: Bool {
        entry.spans.contains { ($0.transcriptSegment ?? "").isEmpty == false }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // ── Top row: phone icon + "Phone Call" + time right-aligned ──
            HStack(spacing: 8) {
                Image(systemName: "phone.fill")
                    .font(.footnote)
                    .foregroundStyle(isInbound ? Color.green : Color.blue)

                Text("Phone Call")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(textSecondary)

                Spacer()

                Text(formattedTime)
                    .font(.caption)
                    .foregroundStyle(textSecondary)
            }

            // ── Title: first line of human_summary ──
            Text(callTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(textPrimary)
                .lineLimit(2)

            // ── Participants ──
            Text(participantsLabel)
                .font(.caption)
                .foregroundStyle(textSecondary)

            // ── Date ──
            if !formattedDate.isEmpty {
                Text(formattedDate)
                    .font(.caption2)
                    .foregroundStyle(textSecondary)
            }

            // ── Summary body (truncated, 200 chars) ──
            if let body = summaryBody {
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(textSecondary)
            }

            // ── "Read Conversation" pill (collapsed by default) ──
            if hasTranscript {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Hide Conversation" : "Read Conversation")
                            .font(.caption)
                            .fontWeight(.medium)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entry.spans) { span in
                            if let text = span.transcriptSegment, !text.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Segment \(span.spanIndex + 1)")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundStyle(textSecondary)

                                    Text(text)
                                        .font(.caption)
                                        .foregroundStyle(textSecondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // ── Claims section ──
            if !allClaims.isEmpty {
                Divider()
                    .overlay(Color.white.opacity(0.1))

                Text("Claims (\(allClaims.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(textSecondary)
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
        }
        .padding(14)
        .background(cardBackground)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isInbound ? Color.green : Color.blue)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }
}
