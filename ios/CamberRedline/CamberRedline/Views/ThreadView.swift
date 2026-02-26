import SwiftUI

// MARK: - Display Group

/// Internal grouping produced by ThreadView to support collapsible call cards
/// that own their associated speaker turns. SMS items remain standalone.
private enum DisplayGroup: Identifiable {
    /// A call header with its associated speaker turns (may be empty if no transcript).
    case callGroup(header: CallHeaderEntry, turns: [SpeakerTurn])
    /// A standalone SMS bubble.
    case smsBubble(SMSEntry)

    var id: String {
        switch self {
        case .callGroup(let header, _):
            return "cg-\(header.interactionId)"
        case .smsBubble(let entry):
            return "sms-\(entry.messageId)"
        }
    }

    /// Best-effort date used for date-separator logic.
    var eventAtDate: Date? {
        switch self {
        case .callGroup(let header, _):
            return ThreadItem.callHeader(header).eventAtDate
        case .smsBubble(let entry):
            return ThreadItem.sms(entry).eventAtDate
        }
    }
}

// MARK: - ThreadView

struct ThreadView: View {
    var viewModel: ThreadViewModel
    let contact: Contact
    @State private var hasScrolledToLatest = false
    private let bottomAnchorID = "thread-bottom-anchor"

    // MARK: - Derived display groups

    /// Collapses the flat `[ThreadItem]` from the ViewModel into display groups
    /// where each `.callHeader` absorbs the `.speakerTurn` items that follow it.
    private var displayGroups: [DisplayGroup] {
        var groups: [DisplayGroup] = []
        var pendingHeader: CallHeaderEntry?
        var pendingTurns: [SpeakerTurn] = []

        func flushPending() {
            guard let header = pendingHeader else { return }
            groups.append(.callGroup(header: header, turns: pendingTurns))
            pendingHeader = nil
            pendingTurns = []
        }

        for item in viewModel.threadItems {
            switch item {
            case .callHeader(let header):
                flushPending()
                pendingHeader = header
                pendingTurns = []

            case .speakerTurn(let turn):
                // Accumulate turns under the current pending call header.
                if pendingHeader != nil {
                    pendingTurns.append(turn)
                }
                // Orphaned speakerTurns (no preceding callHeader) are dropped.

            case .sms(let entry):
                flushPending()
                groups.append(.smsBubble(entry))

            case .call:
                // Legacy .call items — not emitted by the current ViewModel; skip.
                break
            }
        }
        flushPending()
        return groups
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let groups = displayGroups

                    if viewModel.isLoadingOlderThread {
                        ProgressView()
                            .tint(.white)
                            .padding(.vertical, 8)
                    }

                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in

                        // Date separator when the calendar date changes between items.
                        if shouldShowDateSeparator(at: index, in: groups) {
                            DateSeparatorRow(date: group.eventAtDate)
                                .padding(.top, index == 0 ? 12 : 20)
                                .padding(.bottom, 8)
                        }

                        switch group {
                        case .callGroup(let header, let turns):
                            CallCard(
                                header: header,
                                turns: turns,
                                contactName: header.contactName ?? contact.name,
                                viewModel: viewModel
                            )
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                            .onAppear {
                                guard index == 0, hasScrolledToLatest else { return }
                                Task {
                                    await viewModel.loadOlderThreadPageIfNeeded()
                                }
                            }

                        case .smsBubble(let entry):
                            SMSRow(entry: entry, contact: contact)
                                .padding(.horizontal, 16)
                                .padding(.bottom, smsBubbleBottomPadding(at: index, in: groups))
                                .onAppear {
                                    guard index == 0, hasScrolledToLatest else { return }
                                    Task {
                                        await viewModel.loadOlderThreadPageIfNeeded()
                                    }
                                }
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)

                    // Bottom breathing room so content clears the home indicator.
                    Color.clear.frame(height: 20)
                }
            }
            .background(Color.black)
            .refreshable {
                hasScrolledToLatest = false
                await viewModel.loadThread(contactId: contact.contactId)
                for _ in 0..<2 {
                    withAnimation(.none) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                hasScrolledToLatest = true
            }
            .navigationTitle(contact.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .overlay {
                if viewModel.isLoading && viewModel.threadItems.isEmpty {
                    ProgressView()
                        .tint(.white)
                }
            }
            .overlay(alignment: .bottom) {
                if let error = viewModel.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
            .task(id: contact.contactId) {
                hasScrolledToLatest = false
                viewModel.currentContact = contact
                viewModel.threadItems = []
                await viewModel.loadThread(contactId: contact.contactId)
                for _ in 0..<3 {
                    if Task.isCancelled { return }
                    withAnimation(.none) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                hasScrolledToLatest = true
                await viewModel.startClaimGradeSubscription(contactId: contact.contactId)
            }
            .onChange(of: viewModel.threadItems.count) { _, newCount in
                guard newCount > 0, !hasScrolledToLatest else { return }
                withAnimation(.none) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
                hasScrolledToLatest = true
            }
            .onDisappear {
                Task {
                    await viewModel.stopClaimGradeSubscription()
                }
            }
        }
    }

    // MARK: - Date separator logic

    private func shouldShowDateSeparator(at index: Int, in groups: [DisplayGroup]) -> Bool {
        guard let currentDate = groups[index].eventAtDate else { return false }
        if index == 0 { return true }
        guard let previousDate = groups[index - 1].eventAtDate else { return true }
        return !Calendar.current.isDate(currentDate, inSameDayAs: previousDate)
    }

    // MARK: - SMS bubble spacing

    /// Tighter vertical spacing between consecutive same-direction SMS bubbles.
    private func smsBubbleBottomPadding(at index: Int, in groups: [DisplayGroup]) -> CGFloat {
        guard case .smsBubble(let current) = groups[index] else { return 8 }
        let nextIndex = index + 1
        guard nextIndex < groups.count,
              case .smsBubble(let next) = groups[nextIndex] else { return 8 }
        return current.direction == next.direction ? 2 : 8
    }
}

// MARK: - Date Separator Row

/// Centered date + time label displayed between items when the date changes.
/// Formats: "Today 5:29 PM" · "Yesterday 8:39 AM" · "Monday at 5:29 PM" · "Feb 25 10:00 AM"
private struct DateSeparatorRow: View {
    let date: Date?

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var label: String {
        guard let date else { return "Unknown" }
        let cal = Calendar.current
        let time = Self.timeFormatter.string(from: date)

        if cal.isDateInToday(date) {
            return "Today \(time)"
        } else if cal.isDateInYesterday(date) {
            return "Yesterday \(time)"
        } else if let weekday = recentWeekdayName(for: date, cal: cal) {
            return "\(weekday) at \(time)"
        } else {
            return "\(shortMonthDay(for: date)) \(time)"
        }
    }

    /// Returns the weekday name ("Monday", "Tuesday", …) if the date is
    /// 2–6 days ago, otherwise nil.
    private func recentWeekdayName(for date: Date, cal: Calendar) -> String? {
        guard let daysAgo = cal.dateComponents([.day], from: date, to: .now).day,
              daysAgo >= 2, daysAgo <= 6 else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE"
        return fmt.string(from: date)
    }

    /// "Feb 25" format for dates older than 6 days.
    private func shortMonthDay(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }

    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color(.systemGray))
            Spacer()
        }
    }
}

// MARK: - Call Card

/// Call card that shows the header, participants, summary, a collapsible
/// transcript (speaker bubbles), and claims. Transcript is COLLAPSED by default.
private struct CallCard: View {
    let header: CallHeaderEntry
    let turns: [SpeakerTurn]
    /// Resolved contact name ("Zack ↔ <contactName>").
    let contactName: String
    var viewModel: ThreadViewModel

    @State private var transcriptExpanded = false

    private var isInbound: Bool {
        header.direction?.lowercased() == "inbound"
    }

    private var accentColor: Color {
        isInbound
            ? Color(red: 0.19, green: 0.82, blue: 0.35)
            : Color(red: 0, green: 0.48, blue: 1.0)
    }

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var formattedTime: String {
        guard let date = ThreadItem.callHeader(header).eventAtDate else { return "" }
        return Self.timeFormatter.string(from: date)
    }

    /// "Zack ↔ Randy Booth"
    private var participantsLine: String {
        "Zack \u{2194} \(contactName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // --- Header row ---
            HStack(spacing: 10) {
                Image(systemName: "phone.circle.fill")
                    .font(.title2)
                    .foregroundStyle(accentColor)

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

                Image(systemName: isInbound ? "arrow.down.left" : "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // --- Participants line ---
            HStack(spacing: 4) {
                Image(systemName: "person.2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(participantsLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // --- Summary ---
            if let summary = header.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color(.systemGray))
                    .lineLimit(transcriptExpanded ? nil : 2)
            }

            // --- Transcript section ---
            if !turns.isEmpty {
                Divider()
                    .overlay(Color(.systemGray4))

                if transcriptExpanded {
                    // Expanded: render speaker bubbles inline.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(turns.enumerated()), id: \.element.id) { idx, turn in
                            SpeakerTurnBubble(
                                turn: turn,
                                showSpeakerLabel: shouldShowSpeakerLabel(at: idx)
                            )
                            .padding(.bottom, turnBottomSpacing(at: idx))
                        }
                    }
                    .padding(.top, 4)

                    // Collapse button
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            transcriptExpanded = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                            Text("Hide Conversation")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)

                } else {
                    // Collapsed: "Read Conversation" button.
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            transcriptExpanded = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.bubble")
                                .font(.caption2)
                            Text("Read Conversation")
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                            if header.spans.count > 1 {
                                Text("\(header.spans.count) spans")
                                    .font(.caption2)
                                    .foregroundStyle(Color(red: 0.18, green: 0.64, blue: 0.25))
                                Text("\u{00B7}")
                                    .font(.caption2)
                                    .foregroundStyle(Color(.systemGray2))
                            }
                            Text("\(turns.count) turns")
                                .font(.caption2)
                                .foregroundStyle(Color(.systemGray2))
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // --- Spans section ---
            if header.spans.count > 1, transcriptExpanded {
                Divider()
                    .overlay(Color(.systemGray4))

                Text("Project Spans (\(header.spans.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                ForEach(Array(header.spans.sorted { $0.spanIndex < $1.spanIndex }.enumerated()), id: \.element.id) { idx, span in
                    SpanBlock(span: span, colorIndex: idx)
                }
            }

            // --- Claims section ---
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
        // Card background: #1C1C1E
        .background(Color(red: 0.11, green: 0.11, blue: 0.118))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Speaker label helpers

    /// Show the speaker label when the side changes (inbound ↔ outbound transition).
    private func shouldShowSpeakerLabel(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return turns[index].isOwnerSide != turns[index - 1].isOwnerSide
    }

    /// 2 pt spacing between consecutive same-side turns; 8 pt when side changes.
    private func turnBottomSpacing(at index: Int) -> CGFloat {
        guard index + 1 < turns.count else { return 0 }
        return turns[index].isOwnerSide == turns[index + 1].isOwnerSide ? 2 : 8
    }
}

// MARK: - Span Block

/// Color-coded span block showing a project attribution segment.
/// Uses dummy project names until the API returns real attributions.
private struct SpanBlock: View {
    let span: SpanEntry
    let colorIndex: Int

    private static let spanColors: [Color] = [
        Color(red: 0.18, green: 0.64, blue: 0.25),
        Color(red: 0.29, green: 0.56, blue: 0.89),
        Color(red: 0.90, green: 0.62, blue: 0.22),
        Color(red: 0.73, green: 0.33, blue: 0.83),
        Color(red: 0.89, green: 0.32, blue: 0.32),
    ]

    private static let dummyProjects = [
        "Hurley Residence", "Woodbery Residence", "Winship Residence",
        "Skelton Residence", "Sittler Madison",
    ]

    private var color: Color {
        Self.spanColors[colorIndex % Self.spanColors.count]
    }

    private var projectName: String {
        Self.dummyProjects[colorIndex % Self.dummyProjects.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(projectName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
                Spacer()
                Text("Span \(span.spanIndex + 1)")
                    .font(.caption2)
                    .foregroundStyle(Color(.systemGray2))
            }

            if let segment = span.transcriptSegment, !segment.isEmpty {
                Text(segment)
                    .font(.caption)
                    .foregroundStyle(Color(.systemGray))
                    .lineLimit(3)
            }
        }
        .padding(10)
        .background(color.opacity(0.1))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - SMS Row

/// Wraps `SMSBubble` and adds a sender-name label above each bubble (SPEC_1 §5).
private struct SMSRow: View {
    let entry: SMSEntry
    let contact: Contact

    private var isOutbound: Bool {
        entry.direction?.lowercased() == "outbound"
    }

    /// "You" for outbound messages, the contact's name for inbound.
    private var senderName: String {
        isOutbound ? "You" : contact.name
    }

    var body: some View {
        SMSBubble(entry: entry, showTimestamp: true, senderName: senderName)
    }
}
