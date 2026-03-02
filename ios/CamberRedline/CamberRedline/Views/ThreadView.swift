import SwiftUI
import UIKit

// MARK: - Display Group

/// Project attribution for SMS zebra striping (dummy until API provides data).
private struct SMSProjectAssignment: Hashable, Identifiable {
    let projectId: String?
    let name: String
    let colorIndex: Int?

    var id: String {
        if let projectId, !projectId.isEmpty {
            return projectId
        }
        return name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }
}

private struct ThreadNoteTarget: Hashable {
    let type: NoteTargetType
    let id: String
}

private struct ThreadNoteContext: Identifiable {
    let id = UUID()
    let title: String
    let targets: [ThreadNoteTarget]
}

private struct VoicemailModel: Identifiable {
    let id: String
    let from: String
    let eventAt: Date
    let durationSec: Int
    let transcript: String?
}

private struct AISummaryModel: Identifiable {
    let id: String
    let scopeLabel: String
    let createdAt: Date
    let title: String
    let body: String
}

/// Internal grouping produced by ThreadView to support collapsible call cards
/// that own their associated speaker turns. SMS items remain standalone.
private enum DisplayGroup: Identifiable {
    /// A call header with its associated speaker turns (may be empty if no transcript).
    case callGroup(header: CallHeaderEntry, turns: [SpeakerTurn])
    /// A contiguous SMS stripe group (same project assignment).
    case smsGroup(entries: [SMSEntry], assignment: SMSProjectAssignment?)
    /// Dedicated voicemail card path (future-proofed for Beside parity).
    case voicemail(entry: VoicemailModel)
    /// Dedicated AI summary card path (future-proofed for Beside parity).
    case aiSummary(entry: AISummaryModel)

    var id: String {
        switch self {
        case .callGroup(let header, _):
            return "cg-\(header.interactionId)"
        case .smsGroup(let entries, _):
            return "sms-group-\(entries.first?.messageId ?? UUID().uuidString)"
        case .voicemail(let entry):
            return "voicemail-\(entry.id)"
        case .aiSummary(let entry):
            return "ai-summary-\(entry.id)"
        }
    }

    /// Best-effort date used for date-separator logic.
    var eventAtDate: Date? {
        switch self {
        case .callGroup(let header, _):
            return ThreadItem.callHeader(header).eventAtDate
        case .smsGroup(let entries, _):
            guard let entry = entries.first else { return nil }
            return ThreadItem.sms(entry).eventAtDate
        case .voicemail(let entry):
            return entry.eventAt
        case .aiSummary(let entry):
            return entry.createdAt
        }
    }
}

// MARK: - ThreadView

struct ThreadView: View {
    var viewModel: ThreadViewModel
    let contact: Contact
    let orderedContacts: [Contact]
    @AppStorage("internal_truth_graph_status_card_enabled") private var isTruthGraphStatusCardEnabled = true
    @State private var hasScrolledToLatest = false
    @State private var didTriggerTopPagination = false
    @State private var hasUserScrolledThread = false
    @State private var lastObservedTopOffset: CGFloat?
    @State private var smsOverrides: [String: SMSProjectAssignment] = [:]
    @State private var spanOverrides: [UUID: SMSProjectAssignment] = [:]
    @State private var activeNoteContext: ThreadNoteContext?
    @State private var noteDraft = ""
    @State private var isContactInfoPresented = false
    @State private var isRunningTruthGraphRepair = false
    private let bottomAnchorID = "thread-bottom-anchor"
    private let topLoadThreshold: CGFloat = -80
    private static let smsStripeColors: [Color] = [
        Color(red: 0.16, green: 0.32, blue: 0.22),
        Color(red: 0.18, green: 0.26, blue: 0.40),
        Color(red: 0.38, green: 0.24, blue: 0.18),
    ]
    @Environment(\.openURL) private var openURL
    private var reviewProjectOptions: [SMSProjectAssignment] {
        let mapped = viewModel.reviewProjects.enumerated().map { index, project in
            SMSProjectAssignment(projectId: project.id, name: project.name, colorIndex: index)
        }
        let hasUnknown = mapped.contains(where: { $0.projectId == nil })
        if hasUnknown {
            return mapped
        }
        return [SMSProjectAssignment(projectId: nil, name: "Unassigned", colorIndex: nil)] + mapped
    }

    // MARK: - Derived display groups

    /// Collapses the flat `[ThreadItem]` from the ViewModel into display groups
    /// where each `.callHeader` absorbs the `.speakerTurn` items that follow it.
    private var displayGroups: [DisplayGroup] {
        var groups: [DisplayGroup] = []
        var pendingHeader: CallHeaderEntry?
        var pendingTurns: [SpeakerTurn] = []
        var smsIndex = 0
        var pendingSmsEntries: [SMSEntry] = []
        var pendingSmsAssignment: SMSProjectAssignment?
        var pendingSmsGroupKey: String?

        func flushPending() {
            guard let header = pendingHeader else { return }
            groups.append(.callGroup(header: header, turns: pendingTurns))
            pendingHeader = nil
            pendingTurns = []
        }

        func flushSmsGroup() {
            guard !pendingSmsEntries.isEmpty else { return }
            groups.append(.smsGroup(entries: pendingSmsEntries, assignment: pendingSmsAssignment))
            pendingSmsEntries = []
            pendingSmsAssignment = nil
            pendingSmsGroupKey = nil
        }

        for item in viewModel.threadItems {
            switch item {
            case .callHeader(let header):
                flushSmsGroup()
                flushPending()
                let normalizedChannel = header.channel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                if normalizedChannel.contains("voicemail") {
                    let voicemail = VoicemailModel(
                        id: header.interactionId,
                        from: header.contactName ?? contact.name,
                        eventAt: ThreadItem.callHeader(header).eventAtDate ?? .now,
                        durationSec: 0,
                        transcript: header.summary
                    )
                    groups.append(.voicemail(entry: voicemail))
                } else if normalizedChannel.contains("summary") || normalizedChannel.contains("recap") {
                    let summary = AISummaryModel(
                        id: header.interactionId,
                        scopeLabel: "Call Recap",
                        createdAt: ThreadItem.callHeader(header).eventAtDate ?? .now,
                        title: "AI Summary",
                        body: header.summary ?? "No summary available."
                    )
                    groups.append(.aiSummary(entry: summary))
                } else {
                    pendingHeader = header
                    pendingTurns = []
                }

            case .speakerTurn(let turn):
                // Accumulate turns under the current pending call header.
                if pendingHeader != nil {
                    pendingTurns.append(turn)
                }
                // Orphaned speakerTurns (no preceding callHeader) are dropped.

            case .sms(let entry):
                flushPending()
                var assignment = smsProjectAssignment(for: entry)
                if let override = smsOverrides[entry.messageId] {
                    assignment = override
                }
                let groupKey = smsGroupKey(for: entry, assignment: assignment)
                if pendingSmsEntries.isEmpty {
                    pendingSmsAssignment = assignment
                    pendingSmsEntries = [entry]
                    pendingSmsGroupKey = groupKey
                } else if pendingSmsGroupKey == groupKey {
                    pendingSmsEntries.append(entry)
                } else {
                    flushSmsGroup()
                    pendingSmsAssignment = assignment
                    pendingSmsEntries = [entry]
                    pendingSmsGroupKey = groupKey
                }
                smsIndex += 1

            case .call:
                // Legacy .call items — not emitted by the current ViewModel; skip.
                break
            }
        }
        flushSmsGroup()
        flushPending()
        return groups
    }

    // MARK: - Body

    var body: some View {
        let groups = displayGroups
        return ScrollViewReader { proxy in
            ConversationThread {
                    Color.clear
                        .frame(height: 1)
                        .background(
                            GeometryReader { geometry in
                                Color.clear
                                    .preference(
                                        key: ThreadTopOffsetPreferenceKey.self,
                                        value: geometry.frame(in: .named("thread-scroll")).minY
                                    )
                            }
                        )

                    ContactHeader(
                        contactId: contact.contactId.uuidString,
                        displayName: contact.name,
                        avatarSeed: contact.name,
                        presence: nil,
                        unreadCount: contact.ungradedCount,
                        phone: contact.phone,
                        onCall: {
                            guard let phone = contact.phone, !phone.isEmpty else {
                                viewModel.showTransientError("No phone number on file.")
                                return
                            }

                            let sanitized = phone.filter { $0.isNumber || $0 == "+" }
                            guard !sanitized.isEmpty, let url = URL(string: "tel://\(sanitized)") else {
                                viewModel.showTransientError("Invalid phone number.")
                                return
                            }

                            openURL(url)
                        },
                        onInfo: {
                            isContactInfoPresented = true
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                    if viewModel.isLoadingOlderThread {
                        ProgressView()
                            .tint(.white)
                            .padding(.vertical, 8)
                    }

                    let missingCount = missingAttributions(in: groups)
                    if missingCount > 0 {
                        if isTruthGraphStatusCardEnabled {
                            truthGraphStatusCard(missingCount: missingCount)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 10)
                        } else {
                            legacyMissingAttributionBanner(missingCount: missingCount)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 10)
                        }
                    }

                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        groupView(index: index, group: group, groups: groups)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)

                    // Bottom breathing room so content clears the home indicator.
                    Color.clear.frame(height: 20)
            }
            .coordinateSpace(name: "thread-scroll")
            .background(Color.black)
            .refreshable {
                hasScrolledToLatest = false
                didTriggerTopPagination = false
                hasUserScrolledThread = false
                lastObservedTopOffset = nil
                await viewModel.loadThread(contactId: contact.contactId)
                await viewModel.loadReviewProjectsIfNeeded()
                for _ in 0..<2 {
                    withAnimation(.none) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                hasScrolledToLatest = true
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in
                        hasUserScrolledThread = true
                    }
            )
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
                didTriggerTopPagination = false
                hasUserScrolledThread = false
                lastObservedTopOffset = nil
                viewModel.updateContactSequence(orderedContacts)
                viewModel.currentContact = contact
                viewModel.threadItems = []
                // Subscribe FIRST so no Realtime events are missed during REST fetch
                await viewModel.startClaimGradeSubscription(contactId: contact.contactId)
                await viewModel.startInteractionsSubscription(contactId: contact.contactId)
                await viewModel.loadThread(contactId: contact.contactId)
                await viewModel.loadReviewProjectsIfNeeded()
                viewModel.prefetchNextContact(after: contact.contactId)
                for _ in 0..<3 {
                    if Task.isCancelled { return }
                    withAnimation(.none) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                hasScrolledToLatest = true
            }
            .onChange(of: viewModel.threadItems.count) { _, newCount in
                guard newCount > 0 else { return }
                if !hasScrolledToLatest || !hasUserScrolledThread {
                    withAnimation(.none) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                    hasScrolledToLatest = true
                }
            }
            .onPreferenceChange(ThreadTopOffsetPreferenceKey.self) { topY in
                let previousTopY = lastObservedTopOffset
                lastObservedTopOffset = topY

                guard hasScrolledToLatest else { return }
                guard hasUserScrolledThread else { return }
                if topY <= topLoadThreshold - 80 {
                    didTriggerTopPagination = false
                    return
                }
                guard let previousTopY else { return }
                guard topY > previousTopY + 1 else { return }
                guard topY > topLoadThreshold else { return }
                guard !didTriggerTopPagination else { return }
                didTriggerTopPagination = true
                Task {
                    await viewModel.loadOlderThreadPageIfNeeded()
                }
            }
            .onDisappear {
                Task {
                    await viewModel.stopClaimGradeSubscription()
                    await viewModel.stopInteractionsSubscription()
                }
            }
        }
        .sheet(isPresented: $isContactInfoPresented) {
            ContactInfoView(contact: contact)
        }
        .sheet(item: $activeNoteContext) { context in
            NoteEditorSheet(
                title: context.title,
                text: $noteDraft,
                onSave: {
                    for target in context.targets {
                        viewModel.saveNote(
                            targetType: target.type,
                            targetId: target.id,
                            text: noteDraft
                        )
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func groupView(index: Int, group: DisplayGroup, groups: [DisplayGroup]) -> some View {
        if shouldShowDateSeparator(at: index, in: groups) {
            DateSeparator(date: group.eventAtDate)
                .padding(.top, index == 0 ? 12 : 20)
                .padding(.bottom, 8)
        }

        switch group {
        case .callGroup(let header, let turns):
            CallTranscriptCard(
                header: header,
                turns: turns,
                contactName: header.contactName ?? contact.name,
                viewModel: viewModel,
                projectOptions: reviewProjectOptions,
                spanOverrides: spanOverrides,
                onAssignSpanProject: { span, selectedProject in
                    assignSpan(span, to: selectedProject)
                },
                onAddNote: { title, targets in
                    openNoteEditor(title: title, targets: targets)
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

        case .smsGroup(let entries, let assignment):
            SMSStripeGroup(
                entries: entries,
                assignment: assignment,
                stripeColor: stripeColor(for: assignment),
                stripeLabel: assignment?.name,
                unresolvedCount: unresolvedSMSCount(in: entries),
                projectOptions: reviewProjectOptions,
                onAssignProject: { selectedProject in
                    assignSMS(entries, to: selectedProject)
                },
                onOpenPicker: {
                    if reviewProjectOptions.isEmpty {
                        viewModel.showTransientError("Syncing project list…")
                        Task {
                            await viewModel.loadReviewProjectsIfNeeded()
                        }
                    }
                },
                onAddNote: {
                    let label = assignment?.name ?? "SMS"
                    let targets = entries.map {
                        ThreadNoteTarget(type: .sms, id: $0.messageId)
                    }
                    openNoteEditor(title: "Notes — \(label)", targets: targets)
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

        case .voicemail(let entry):
            VoicemailCard(entry: entry)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

        case .aiSummary(let entry):
            AISummaryCard(entry: entry)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private func assignSpan(_ span: SpanEntry, to selectedProject: SMSProjectAssignment) {
        spanOverrides[span.spanId] = selectedProject
        guard let queueId = span.reviewQueueId else { return }
        guard let projectId = selectedProject.projectId else {
            spanOverrides.removeValue(forKey: span.spanId)
            viewModel.showTransientError("Select a project before applying attribution.")
            return
        }
        Task {
            let didResolve = await viewModel.resolveAttribution(
                reviewQueueId: queueId,
                projectId: projectId
            )
            if !didResolve {
                spanOverrides.removeValue(forKey: span.spanId)
            } else {
                await MainActor.run {
                    triggerAssignmentHaptic()
                }
            }
        }
    }

    private func assignSMS(_ entries: [SMSEntry], to selectedProject: SMSProjectAssignment) {
        guard let projectId = selectedProject.projectId else {
            viewModel.showTransientError("Select a project before applying attribution.")
            return
        }
        for id in entries.map(\.messageId) {
            smsOverrides[id] = selectedProject
        }
        let queueIds = entries
            .compactMap { entry -> String? in
                guard entry.needsAttribution else { return nil }
                return entry.reviewQueueId
            }
        guard !queueIds.isEmpty else { return }
        Task {
            let didResolve = await viewModel.resolveAttributions(
                reviewQueueIds: queueIds,
                projectId: projectId
            )
            if !didResolve {
                for id in entries.map(\.messageId) {
                    smsOverrides.removeValue(forKey: id)
                }
            } else {
                await MainActor.run {
                    triggerAssignmentHaptic()
                }
            }
        }
    }

    // MARK: - Date separator logic

    private func missingAttributions(in groups: [DisplayGroup]) -> Int {
        groups.reduce(0) { partial, group in
            switch group {
            case .callGroup(let header, _):
                let optimisticResolved = header.spans.filter {
                    $0.needsAttribution && spanOverrides[$0.spanId] != nil
                }.count
                return partial + max(0, header.pendingAttributionCount - optimisticResolved)
            case .smsGroup(let entries, _):
                let pendingQueueIds = Set(
                    entries.compactMap { entry -> String? in
                        guard entry.needsAttribution else { return nil }
                        return entry.reviewQueueId
                    }
                )
                let optimisticResolvedQueueIds = Set(
                    entries.compactMap { entry -> String? in
                        guard
                            entry.needsAttribution,
                            smsOverrides[entry.messageId]?.projectId != nil
                        else { return nil }
                        return entry.reviewQueueId
                    }
                )
                return partial + max(0, pendingQueueIds.count - optimisticResolvedQueueIds.count)
            case .voicemail, .aiSummary:
                return partial
            }
        }
    }

    @ViewBuilder
    private func legacyMissingAttributionBanner(missingCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(missingCount) attribution\(missingCount == 1 ? "" : "s") still missing in this thread")
                .font(.caption)
                .fontWeight(.semibold)
            Spacer()
        }
        .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.23))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.20, green: 0.12, blue: 0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func truthGraphStatusCard(missingCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline)
                    .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.23))
                Text("Truth Graph status")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text("INTERNAL")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.95, green: 0.62, blue: 0.23), in: Capsule())
                Spacer()
                if isRunningTruthGraphRepair {
                    ProgressView()
                        .tint(Color(red: 0.95, green: 0.62, blue: 0.23))
                        .scaleEffect(0.8)
                }
            }

            Text("\(missingCount) attribution\(missingCount == 1 ? "" : "s") still missing. Evidence is visible and repairable from this thread.")
                .font(.caption)
                .foregroundStyle(Color(.systemGray2))

            Text("Repair routes: refresh thread state, refresh project candidates, then resolve missing items in call cards below.")
                .font(.caption2)
                .foregroundStyle(Color(.systemGray3))

            HStack(spacing: 8) {
                Button {
                    runTruthGraphRepair(refreshProjects: false)
                } label: {
                    Label("Refresh Thread", systemImage: "arrow.clockwise")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.95, green: 0.62, blue: 0.23))
                .disabled(isRunningTruthGraphRepair)

                Button {
                    runTruthGraphRepair(refreshProjects: true)
                } label: {
                    Label("Refresh + Projects", systemImage: "wand.and.stars")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .tint(Color(red: 0.95, green: 0.62, blue: 0.23))
                .disabled(isRunningTruthGraphRepair)
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.10, blue: 0.06),
                    Color(red: 0.09, green: 0.08, blue: 0.12),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.95, green: 0.62, blue: 0.23).opacity(0.35), lineWidth: 1)
        )
    }

    private func runTruthGraphRepair(refreshProjects: Bool) {
        guard !isRunningTruthGraphRepair else { return }
        isRunningTruthGraphRepair = true
        Task {
            await viewModel.loadThread(contactId: contact.contactId)
            if refreshProjects {
                await viewModel.loadReviewProjectsIfNeeded()
            }
            await MainActor.run {
                isRunningTruthGraphRepair = false
            }
        }
    }

    private func shouldShowDateSeparator(at index: Int, in groups: [DisplayGroup]) -> Bool {
        guard let currentDate = groups[index].eventAtDate else { return false }
        if index == 0 { return true }
        guard let previousDate = groups[index - 1].eventAtDate else { return true }
        return !Calendar.current.isDate(currentDate, inSameDayAs: previousDate)
    }

    // MARK: - SMS zebra striping

    private func smsProjectAssignment(for entry: SMSEntry) -> SMSProjectAssignment? {
        if entry.needsAttribution {
            return SMSProjectAssignment(projectId: nil, name: "Needs Attribution", colorIndex: nil)
        }
        return nil
    }

    private func smsGroupKey(for entry: SMSEntry, assignment: SMSProjectAssignment?) -> String {
        let assignmentKey = assignment?.id ?? "none"
        if assignment?.projectId != nil {
            return assignmentKey
        }
        let queueKey = entry.reviewQueueId ?? "none"
        return "\(assignmentKey)|\(queueKey)"
    }

    private func unresolvedSMSCount(in entries: [SMSEntry]) -> Int {
        let pendingQueueIds = Set(
            entries.compactMap { entry -> String? in
                guard entry.needsAttribution else { return nil }
                return entry.reviewQueueId
            }
        )
        let optimisticResolvedQueueIds = Set(
            entries.compactMap { entry -> String? in
                guard
                    entry.needsAttribution,
                    smsOverrides[entry.messageId]?.projectId != nil
                else { return nil }
                return entry.reviewQueueId
            }
        )
        return max(0, pendingQueueIds.count - optimisticResolvedQueueIds.count)
    }

    private func stripeColor(for assignment: SMSProjectAssignment?) -> Color? {
        guard let assignment else { return nil }
        if assignment.name == "Needs Attribution" {
            return Color(red: 0.46, green: 0.29, blue: 0.08)
        }
        guard let colorIndex = assignment.colorIndex else {
            return Color(red: 0.22, green: 0.22, blue: 0.24)
        }
        return Self.smsStripeColors[colorIndex % Self.smsStripeColors.count]
    }

    private func openNoteEditor(title: String, targets: [ThreadNoteTarget]) {
        guard let first = targets.first else { return }
        noteDraft = viewModel.noteText(targetType: first.type, targetId: first.id)
        activeNoteContext = ThreadNoteContext(title: title, targets: targets)
    }

    private func triggerAssignmentHaptic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

private struct ThreadTopOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = -.greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Date Separator Row

/// Centered date + time label displayed between items when the date changes.
/// Formats: "Today 5:29 PM" · "Yesterday 8:39 AM" · "Monday at 5:29 PM" · "Feb 25 10:00 AM"
private struct DateSeparator: View {
    let date: Date?

    private static let timeFormatter: DateFormatter = {
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

private struct ConversationThread<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                content()
            }
        }
    }
}

private struct ContactHeader: View {
    let contactId: String
    let displayName: String
    let avatarSeed: String
    let presence: String?
    let unreadCount: Int
    let phone: String?
    let onCall: () -> Void
    let onInfo: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var initials: String {
        let parts = displayName
            .split(separator: " ")
            .prefix(2)
            .map { String($0.prefix(1)).uppercased() }
        return parts.isEmpty ? "?" : parts.joined()
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(red: 0.20, green: 0.20, blue: 0.24))
                .frame(width: horizontalSizeClass == .compact ? 38 : 44, height: horizontalSizeClass == .compact ? 38 : 44)
                .overlay(
                    Text(initials)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let phone, !phone.isEmpty {
                        Text(phone)
                    } else {
                        Text("ID \(contactId.prefix(6))…")
                    }
                    if unreadCount > 0 {
                        Text("\(unreadCount) pending")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.23))
                    }
                    if let presence, !presence.isEmpty {
                        Text(presence)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color(.systemGray2))
            }

            Spacer()

            HStack(spacing: 8) {
                NavigationLink(destination: AssistantChatView(contactId: contactId, initialMessage: "What's the latest with \(displayName)?")) {
                    Image(systemName: "brain.head.profile")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color(red: 0.369, green: 0.361, blue: 0.902), in: Circle())
                }
                .buttonStyle(.plain)

                Button(action: onCall) {
                    Image(systemName: "phone.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color(red: 0.16, green: 0.50, blue: 0.94), in: Circle())
                }
                .buttonStyle(.plain)

                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(Color(.systemGray2))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.09, blue: 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct NoteIconButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.caption)
                .foregroundStyle(Color(.systemGray2))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

private struct MessageBubble: View {
    let entry: SMSEntry
    let showTimestamp: Bool

    var body: some View {
        SMSBubble(entry: entry, showTimestamp: showTimestamp)
    }
}

private struct VoicemailCard: View {
    let entry: VoicemailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color(red: 0.29, green: 0.56, blue: 0.89))
                Text("Voicemail")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Spacer()
                Text("\(entry.durationSec)s")
                    .font(.caption)
                    .foregroundStyle(Color(.systemGray2))
            }
            Text("From \(entry.from)")
                .font(.caption)
                .foregroundStyle(Color(.systemGray2))
            if let transcript = entry.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.caption)
                    .foregroundStyle(Color(.systemGray))
                    .lineLimit(4)
            } else {
                Text("Transcript unavailable.")
                    .font(.caption)
                    .foregroundStyle(Color(.systemGray3))
            }
        }
        .padding(14)
        .background(Color(red: 0.11, green: 0.11, blue: 0.118), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AISummaryCard: View {
    let entry: AISummaryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.23))
                Text(entry.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Spacer()
                Text(entry.scopeLabel)
                    .font(.caption2)
                    .foregroundStyle(Color(.systemGray2))
            }
            Text(entry.body)
                .font(.caption)
                .foregroundStyle(Color(.systemGray))
                .lineLimit(6)
        }
        .padding(14)
        .background(Color(red: 0.11, green: 0.11, blue: 0.118), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Call Card

/// Call card that shows the header, participants, summary, a collapsible
/// transcript (speaker bubbles), and claims. Transcript is COLLAPSED by default.
private struct CallTranscriptCard: View {
    let header: CallHeaderEntry
    let turns: [SpeakerTurn]
    /// Resolved contact name ("Zack ↔ <contactName>").
    let contactName: String
    var viewModel: ThreadViewModel
    let projectOptions: [SMSProjectAssignment]
    let spanOverrides: [UUID: SMSProjectAssignment]
    let onAssignSpanProject: (SpanEntry, SMSProjectAssignment) -> Void
    let onAddNote: (String, [ThreadNoteTarget]) -> Void

    @State private var transcriptExpanded = false
    @State private var claimsExpanded: Bool

    init(header: CallHeaderEntry, turns: [SpeakerTurn], contactName: String,
         viewModel: ThreadViewModel, projectOptions: [SMSProjectAssignment],
         spanOverrides: [UUID: SMSProjectAssignment],
         onAssignSpanProject: @escaping (SpanEntry, SMSProjectAssignment) -> Void,
         onAddNote: @escaping (String, [ThreadNoteTarget]) -> Void) {
        self.header = header
        self.turns = turns
        self.contactName = contactName
        self.viewModel = viewModel
        self.projectOptions = projectOptions
        self.spanOverrides = spanOverrides
        self.onAssignSpanProject = onAssignSpanProject
        self.onAddNote = onAddNote
        // Auto-expand claims when there are ungraded claims
        let hasUngraded = header.claims.contains { $0.grade == nil || $0.grade!.isEmpty }
        _claimsExpanded = State(initialValue: hasUngraded)
    }

    private var isInbound: Bool {
        header.direction?.lowercased() == "inbound"
    }

    private var accentColor: Color {
        isInbound
            ? Color(red: 0.19, green: 0.82, blue: 0.35)
            : Color(red: 0, green: 0.48, blue: 1.0)
    }

    private static let timeFormatter: DateFormatter = {
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

    private var unresolvedCount: Int {
        let pending = header.pendingAttributionCount
        let optimisticResolved = header.spans.filter {
            $0.needsAttribution && spanOverrides[$0.spanId] != nil
        }.count
        return max(0, pending - optimisticResolved)
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

            if unresolvedCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("\(unresolvedCount) unassigned item\(unresolvedCount == 1 ? "" : "s")")
                        .font(.caption)
                        .fontWeight(.semibold)
                    if projectOptions.isEmpty {
                        Spacer(minLength: 8)
                        Text("Loading projects…")
                            .font(.caption2)
                            .foregroundStyle(Color(.systemGray3))
                    }
                }
                .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.23))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 0.33, green: 0.20, blue: 0.07), in: Capsule())
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
            if !header.spans.isEmpty {
                // Span boxes are the transcript. Each expands to bubbles.
                Divider()
                    .overlay(Color(.systemGray4))

                ForEach(Array(header.spans.sorted { $0.spanIndex < $1.spanIndex }.enumerated()), id: \.element.id) { idx, span in
                    SpanBlock(
                        span: span,
                        colorIndex: idx,
                        contactName: contactName,
                        selectedAssignment: spanOverrides[span.spanId],
                        projectOptions: projectOptions,
                        onSelectProject: { selected in
                            onAssignSpanProject(span, selected)
                        },
                        onAddNote: onAddNote
                    )
                }

            } else if !turns.isEmpty {
                // Single-span: existing speaker bubble transcript.
                Divider()
                    .overlay(Color(.systemGray4))

                Group {
                    if transcriptExpanded {
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
                .onLongPressGesture(minimumDuration: 0.25) {
                    onAddNote(
                        "Notes — Call Transcript",
                        [ThreadNoteTarget(type: .call, id: header.interactionId)]
                    )
                }
            }

            // --- Claims section ---
            if !header.claims.isEmpty {
                Divider()
                    .overlay(Color(.systemGray4))

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        claimsExpanded.toggle()
                    }
                } label: {
                    let ungradedCount = header.claims.filter { $0.grade == nil || $0.grade!.isEmpty }.count
                    HStack(spacing: 6) {
                        Text("Claims (\(header.claims.count))")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        if ungradedCount > 0 {
                            Text("\(ungradedCount) to grade")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.7))
                                .clipShape(Capsule())
                        }

                        Spacer()
                        Image(systemName: claimsExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if claimsExpanded {
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
/// Tap to expand into speaker bubbles. Long-press for attribution change.
/// Uses dummy project names until the API returns real attributions.
private struct SpanBlock: View {
    let span: SpanEntry
    let colorIndex: Int
    let contactName: String
    let selectedAssignment: SMSProjectAssignment?
    let projectOptions: [SMSProjectAssignment]
    let onSelectProject: (SMSProjectAssignment) -> Void
    let onAddNote: (String, [ThreadNoteTarget]) -> Void

    @State private var isExpanded = false
    @State private var showProjectSheet = false

    private static let spanColors: [Color] = [
        Color(red: 0.18, green: 0.64, blue: 0.25),
        Color(red: 0.29, green: 0.56, blue: 0.89),
        Color(red: 0.90, green: 0.62, blue: 0.22),
        Color(red: 0.73, green: 0.33, blue: 0.83),
        Color(red: 0.89, green: 0.32, blue: 0.32),
    ]

    private var currentProject: SMSProjectAssignment {
        if let selectedAssignment {
            return selectedAssignment
        }
        if let resolvedProject = resolvedProjectAssignment {
            return resolvedProject
        }
        if span.needsAttribution {
            return SMSProjectAssignment(projectId: nil, name: "Unassigned", colorIndex: nil)
        }
        return SMSProjectAssignment(projectId: nil, name: "Unassigned", colorIndex: nil)
    }

    private var displayProjectName: String? {
        if span.needsAttribution && selectedAssignment == nil {
            return nil
        }
        return currentProject.name
    }

    private var resolvedProjectAssignment: SMSProjectAssignment? {
        return nil
    }

    private var color: Color {
        guard let colorIndex = currentProject.colorIndex else {
            return Color(red: 0.30, green: 0.30, blue: 0.33)
        }
        return Self.spanColors[colorIndex % Self.spanColors.count]
    }

    private var parsedTurns: [SpeakerTurn] {
        guard let segment = span.transcriptSegment, !segment.isEmpty else { return [] }
        return TranscriptParser.parse(segment, contactName: contactName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: project marker + expand chevron. Tap always expands.
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                if let displayProjectName {
                    Text(displayProjectName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                } else if span.needsAttribution && selectedAssignment == nil {
                    Text("Unassigned")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.23))
                }
                Spacer()

                // Visible "Assign" button when attribution is needed
                if span.needsAttribution && selectedAssignment == nil {
                    Button {
                        showProjectSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.caption2)
                            Text("Assign")
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.95, green: 0.62, blue: 0.23).opacity(0.85))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                NoteIconButton(label: "Add note") {
                    onAddNote(
                        "Notes — Conversation segment",
                        [ThreadNoteTarget(type: .span, id: span.spanId.uuidString)]
                    )
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Color(.systemGray3))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Tap on header always expands/collapses — consistent behavior
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                // Expanded: speaker bubbles for this span's transcript segment.
                let turns = parsedTurns
                if !turns.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(turns.enumerated()), id: \.offset) { idx, turn in
                            SpeakerTurnBubble(
                                turn: turn,
                                showSpeakerLabel: idx == 0 || turn.isOwnerSide != turns[idx - 1].isOwnerSide
                            )
                            .padding(.bottom, idx + 1 < turns.count
                                ? (turn.isOwnerSide == turns[idx + 1].isOwnerSide ? 2 : 8)
                                : 0)
                        }
                    }
                    .padding(.top, 4)
                }

                // Reassign button at bottom of expanded span (for already-assigned spans)
                if !span.needsAttribution || selectedAssignment != nil {
                    Button {
                        showProjectSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                            Text("Reassign Project")
                                .font(.caption2)
                        }
                        .foregroundStyle(Color(.systemGray2))
                        .padding(.top, 6)
                    }
                    .buttonStyle(.plain)
                }
            } else if let segment = span.transcriptSegment, !segment.isEmpty {
                // Compressed: 3-line text preview. Tappable to expand.
                Text(segment)
                    .font(.caption)
                    .foregroundStyle(Color(.systemGray))
                    .lineLimit(3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    }
            }
        }
        .padding(10)
        .background(color.opacity(currentProject.colorIndex == nil ? 0.16 : 0.10))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .sheet(isPresented: $showProjectSheet) {
            ProjectAssignmentSheet(
                title: "Assign Project",
                currentAssignment: currentProject,
                options: projectOptions,
                onSelect: { selected in
                    onSelectProject(selected)
                },
                onAddNote: {
                    onAddNote(
                        "Notes — Conversation segment",
                        [ThreadNoteTarget(type: .span, id: span.spanId.uuidString)]
                    )
                }
            )
        }
    }
}

// MARK: - SMS Row

/// Wraps `SMSBubble` and applies optional attribution stripe styling.
private struct SMSStripeGroup: View {
    let entries: [SMSEntry]
    let assignment: SMSProjectAssignment?
    let stripeColor: Color?
    let stripeLabel: String?
    let unresolvedCount: Int
    let projectOptions: [SMSProjectAssignment]
    let onAssignProject: (SMSProjectAssignment) -> Void
    let onOpenPicker: () -> Void
    let onAddNote: () -> Void

    @State private var showProjectSheet = false

    private var stripeShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let stripeColor {
                stripeShape
                    .fill(stripeColor.opacity(0.36))
            }

            VStack(alignment: .leading, spacing: 0) {
                if let stripeLabel {
                    HStack(spacing: 8) {
                        if unresolvedCount == 0 {
                            Button {
                                onOpenPicker()
                                showProjectSheet = true
                            } label: {
                                Text(stripeLabel)
                                    .font(.caption2)
                                    .foregroundStyle(Color(.systemGray2))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(stripeLabel)
                                .font(.caption2)
                                .foregroundStyle(Color(.systemGray2))
                        }

                        Spacer()

                        NoteIconButton(label: "Add note") {
                            onAddNote()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                }

                if unresolvedCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("\(unresolvedCount) unassigned item\(unresolvedCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .fontWeight(.semibold)

                        Spacer()

                        NoteIconButton(label: "Add note") {
                            onAddNote()
                        }

                        Button {
                            onOpenPicker()
                            showProjectSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.badge.questionmark")
                                    .font(.caption2)
                                Text("Assign")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(red: 0.95, green: 0.62, blue: 0.23).opacity(0.85))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.23))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                }

                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                    MessageBubble(entry: entry, showTimestamp: true)
                        .padding(.bottom, bubbleSpacing(at: idx))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(isPresented: $showProjectSheet) {
            ProjectAssignmentSheet(
                title: "Assign Project",
                currentAssignment: assignment,
                options: projectOptions,
                onSelect: onAssignProject,
                onAddNote: onAddNote
            )
        }
    }

    private func bubbleSpacing(at index: Int) -> CGFloat {
        guard index + 1 < entries.count else { return 6 }
        let current = entries[index]
        let next = entries[index + 1]
        let sameDirection = current.direction == next.direction
        return sameDirection ? 2 : 8
    }
}

private struct ProjectAssignmentSheet: View {
    let title: String
    let currentAssignment: SMSProjectAssignment?
    let options: [SMSProjectAssignment]
    let onSelect: (SMSProjectAssignment) -> Void
    let onAddNote: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private static let optionColors: [Color] = [
        Color(red: 0.18, green: 0.64, blue: 0.25),
        Color(red: 0.29, green: 0.56, blue: 0.89),
        Color(red: 0.90, green: 0.62, blue: 0.22),
        Color(red: 0.73, green: 0.33, blue: 0.83),
        Color(red: 0.89, green: 0.32, blue: 0.32),
        Color(red: 0.36, green: 0.73, blue: 0.80),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Project") {
                    if options.isEmpty {
                        Text("No projects available yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(options) { option in
                            Button {
                                onSelect(option)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(color(for: option))
                                        .frame(width: 9, height: 9)
                                    Text(option.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if currentAssignment?.id == option.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .frame(minHeight: 54, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }

                if let onAddNote {
                    Section {
                        Button("Add Note…") {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                onAddNote()
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func color(for option: SMSProjectAssignment) -> Color {
        guard let idx = option.colorIndex else {
            return Color(red: 0.34, green: 0.34, blue: 0.36)
        }
        return Self.optionColors[idx % Self.optionColors.count]
    }
}

// MARK: - Note Editor

private struct NoteEditorSheet: View {
    let title: String
    @Binding var text: String
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(minHeight: 180)
            }
            .padding(16)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
    }
}
