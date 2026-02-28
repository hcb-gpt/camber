import SwiftUI

// MARK: - Design tokens
private let cardBackground = Color(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0)
private let textPrimary    = Color.white
private let textSecondary  = Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
private let cardRadius: CGFloat = 16

struct CallHeaderCard: View {
    let header: CallHeaderEntry
    var viewModel: ThreadViewModel

    private var isInbound: Bool {
        header.direction?.lowercased() == "inbound"
    }

    // MARK: - Formatters

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var eventDate: Date? {
        ThreadItem.callHeader(header).eventAtDate
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

    /// First non-empty line of the human summary, falling back to "Phone Call".
    private var callTitle: String {
        guard let summary = header.summary, !summary.isEmpty else { return "Phone Call" }
        let firstLine = summary
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? "Phone Call"
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    /// "👤 Zack ↔ {contactName}" — uses contactName when available.
    private var participantsLabel: String {
        if let contact = header.contactName, !contact.isEmpty {
            return "👤 Zack ↔ \(contact)"
        }
        return "👤 Zack"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // ── Top row: phone icon + "Phone Call" label + time right-aligned ──
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

            // ── Claims section ──
            if !header.claims.isEmpty {
                Divider()
                    .overlay(Color.white.opacity(0.1))

                Text("Claims (\(header.claims.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(textSecondary)
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
        .background(cardBackground)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isInbound ? Color.green : Color.blue)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }
}
