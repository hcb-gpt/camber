import SwiftUI
import os

private enum TriageSmokeAutomation {
    static let launchFlag = "--smoke-drive"
    static let syntheticIdsFlag = "--smoke-synthetic-ids"
    static let keepUndoFlag = "--smoke-triage-keep-undo"
    static let triageNotification = Notification.Name("camber.smoke.runTriage")
    static let triageDoneNotification = Notification.Name("camber.smoke.triageDone")
    static let logger = Logger(subsystem: "CamberRedline", category: "smoke")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }

    static var targetInteractionIds: Set<String> {
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: syntheticIdsFlag), flagIndex + 1 < args.count else {
            return []
        }
        let raw = args[flagIndex + 1]
        let values = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(values)
    }

    static var shouldKeepUndoBanner: Bool {
        ProcessInfo.processInfo.arguments.contains(keepUndoFlag)
    }
}

private enum TriageProofAutomation {
    static let openEvidenceFlag = "--smoke-triage-open-evidence"

    static var shouldAutoOpenEvidence: Bool {
        ProcessInfo.processInfo.arguments.contains(openEvidenceFlag)
    }
}

private extension Color {
    static let cardsBg = Color.black
    static let cardFace = Color(red: 0.082, green: 0.082, blue: 0.09)     // #151517
    static let cardStroke = Color(red: 0.165, green: 0.165, blue: 0.18)    // #2A2A2E
    static let chipBg = Color(red: 0.145, green: 0.145, blue: 0.157)      // #252528
    static let yesGreen = Color(red: 0.188, green: 0.82, blue: 0.345)     // #30D158
    static let noRed = Color(red: 1.0, green: 0.231, blue: 0.188)         // #FF3B30
    static let undoAmber = Color(red: 1.0, green: 0.624, blue: 0.04)      // #FF9F0A
    static let commentBlue = Color(red: 0.188, green: 0.478, blue: 1.0)   // #307AFF
    static let escalateOrange = Color(red: 1.0, green: 0.584, blue: 0.0)  // #FF9500
    static let skipGray = Color(red: 0.557, green: 0.557, blue: 0.576)    // #8E8E93
}

struct AttributionTriageCardsView: View {
    @State private var viewModel = CardTriageViewModel()
    @State private var showProjectPicker = false
    @State private var pickerCard: CardItem?
    @State private var pickerMode: PickerMode = .project
    @State private var pickedProjectByQueueId: [String: String] = [:]
    @State private var pendingResolveNote: String?
    @State private var showCommentComposer = false
    @State private var commentCard: CardItem?
    @State private var didRunSmokeTriage = false
    @State private var showEscalateSheet = false
    @State private var escalateCard: CardItem?
    @State private var showAnalysisDrawer = false
    @State private var analysisCard: CardItem?
    @State private var showEvidenceSheet = false
    @State private var evidenceCard: CardItem?
    @State private var didAutoOpenEvidenceSheet = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.cardsBg.ignoresSafeArea()

                if viewModel.isLoading && viewModel.queue.isEmpty {
                    ProgressView("Loading triage queue...")
                        .tint(.white)
                        .foregroundStyle(.secondary)
                } else if viewModel.queue.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        if let banner = viewModel.attributionWritesLockedBannerText {
                            writesLockedBanner(banner)
                        }
                        activityRail
                        progressBar
                        cardStack
                        actionHints
                    }
                }

                if viewModel.lastAction != nil, viewModel.canUndo {
                    undoBanner(viewModel.lastAction!)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let error = viewModel.error {
                    errorBanner(error)
                }
            }
            .navigationTitle("Triage")
            .task {
                if viewModel.queue.isEmpty {
                    await viewModel.loadQueue()
                }

                if TriageProofAutomation.shouldAutoOpenEvidence,
                   !didAutoOpenEvidenceSheet,
                   let card = viewModel.queue.first
                {
                    didAutoOpenEvidenceSheet = true
                    evidenceCard = card
                    showEvidenceSheet = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: TriageSmokeAutomation.triageNotification)) { _ in
                guard TriageSmokeAutomation.isEnabled else { return }
                guard !didRunSmokeTriage else { return }
                didRunSmokeTriage = true
                Task { await runSmokeSwipes() }
            }
            .sheet(isPresented: $showProjectPicker) {
                if let card = pickerCard {
                    ProjectPickerSheet(
                        card: card,
                        projects: viewModel.projectOptions(for: card),
                        onSelect: { projectId in
                            let notes = pendingResolveNote
                            pendingResolveNote = nil
                            if pickerMode == .commentOnly {
                                Task { await viewModel.resolve(card, to: projectId, notes: notes) }
                                pickedProjectByQueueId.removeValue(forKey: card.queueId)
                            } else {
                                if pickedProjectByQueueId[card.queueId] == nil {
                                    viewModel.recordPickTime()
                                }
                                pickedProjectByQueueId[card.queueId] = projectId
                            }
                        },
                        onDismissItem: {
                            Task { await viewModel.dismiss(card) }
                            pickedProjectByQueueId.removeValue(forKey: card.queueId)
                        },
                        onBizDevNoProject: {
                            Task {
                                await viewModel.dismiss(
                                    card,
                                    reason: "bizdev_no_project",
                                    notes: "no_project_selected"
                                )
                            }
                            pickedProjectByQueueId.removeValue(forKey: card.queueId)
                        },
                        showsDismissAction: pickerMode != .commentOnly,
                        writesLocked: viewModel.isAttributionWritesLocked,
                        writesLockedBannerText: viewModel.attributionWritesLockedBannerText
                    )
                }
            }
            .sheet(isPresented: $showCommentComposer) {
                if let card = commentCard {
                    TriageCommentSheet(
                        card: card,
                        suggestedProjectName: viewModel.projectName(for: card.projectId),
                        onCancel: {
                            commentCard = nil
                        },
                        onSubmit: { note in
                            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                            let finalNote = trimmed.isEmpty ? nil : trimmed
                            if let projectId = card.projectId {
                                Task { await viewModel.resolve(card, to: projectId, notes: finalNote) }
                            } else {
                                pendingResolveNote = finalNote
                                pickerMode = .commentOnly
                                pickerCard = card
                                showProjectPicker = true
                            }
                            commentCard = nil
                        }
                    )
                }
            }
            .sheet(isPresented: $showEscalateSheet) {
                if let card = escalateCard {
                    EscalateReasonSheet(
                        card: card,
                        onCancel: { escalateCard = nil },
                        onSubmit: { reason in
                            Task { await viewModel.escalate(card, reason: reason) }
                            escalateCard = nil
                        }
                    )
                }
            }
            .sheet(isPresented: $showAnalysisDrawer) {
                if let card = analysisCard {
                    AnalysisDrawerSheet(
                        card: card,
                        projectName: viewModel.projectName(for: card.projectId)
                    )
                }
            }
            .sheet(isPresented: $showEvidenceSheet) {
                if let card = evidenceCard {
                    EvidenceTokenSheet(card: card)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Activity Rail

    private var activityRail: some View {
        HStack(spacing: 16) {
            railStat(
                icon: "checkmark.circle.fill",
                value: "\(viewModel.resolvedCount)",
                label: "done",
                color: .yesGreen
            )
            railStat(
                icon: "arrow.triangle.2.circlepath",
                value: "\(viewModel.skippedCount)",
                label: "skip",
                color: .skipGray
            )
            railStat(
                icon: "exclamationmark.triangle.fill",
                value: "\(viewModel.escalatedCount)",
                label: "esc",
                color: .escalateOrange
            )
            Spacer()
            railStat(
                icon: "hand.tap",
                value: viewModel.pickTimeP90Seconds.map { "\($0)s" } ?? "—",
                label: "pick p90",
                color: .white
            )
            railStat(
                icon: "gauge.open.with.lines.needle.33percent",
                value: "\(Int(viewModel.resolveRatePerHour))/h",
                label: "rate",
                color: .commentBlue
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func railStat(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color.opacity(0.7))
                Text(value)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(viewModel.resolvedCount) done, \(viewModel.queue.count) remaining of \(viewModel.resolvedCount + viewModel.queue.count) today")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.cardStroke)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.yesGreen)
                        .frame(width: geo.size.width * viewModel.progressFraction, height: 4)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.progressFraction)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: - Card Stack

    private var cardStack: some View {
        ZStack {
            ForEach(Array(viewModel.queue.prefix(3).enumerated().reversed()), id: \.element.id) { index, card in
                let isTop = index == 0
                let pickedProjectId = pickedProjectByQueueId[card.queueId]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                let pickedProjectName = pickedProjectId.flatMap { viewModel.projectName(for: $0) }
                let hasExplicitPick = pickedProjectId != nil
                SwipeableTriageCard(
                    card: card,
                    projectName: viewModel.projectName(for: card.projectId),
                    selectedProjectName: pickedProjectName,
                    isTop: isTop,
                    writesLocked: viewModel.isAttributionWritesLocked,
                    onBlockedWrite: {
                        if let banner = viewModel.attributionWritesLockedBannerText {
                            viewModel.error = banner
                        }
                    },
                    onConfirmLocked: {
                        viewModel.error = "Confirm is locked. Pick a project first."
                    },
                    onSelectSuggested: {
                        guard let suggested = card.projectId else { return }
                        let trimmed = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if pickedProjectByQueueId[card.queueId] == nil {
                            viewModel.recordPickTime()
                        }
                        pickedProjectByQueueId[card.queueId] = trimmed
                    },
                    onTapEvidence: {
                        evidenceCard = card
                        showEvidenceSheet = true
                    },
                    onSwipeRight: {
                        guard hasExplicitPick, let projectId = pickedProjectId else {
                            viewModel.error = "Confirm is locked. Pick a project first."
                            return
                        }
                        pickedProjectByQueueId.removeValue(forKey: card.queueId)
                        Task { await viewModel.resolve(card, to: projectId) }
                    },
                    onSwipeLeft: {
                        pickerMode = .project
                        pickerCard = card
                        showProjectPicker = true
                    },
                    onSwipeUp: {
                        escalateCard = card
                        showEscalateSheet = true
                    },
                    onSwipeDown: {
                        viewModel.skip(card)
                        pickedProjectByQueueId.removeValue(forKey: card.queueId)
                    },
                    onTapAnalysis: {
                        analysisCard = card
                        showAnalysisDrawer = true
                    }
                )
                .zIndex(isTop ? 1 : 0)
                .scaleEffect(1.0 - CGFloat(index) * 0.04)
                .offset(y: CGFloat(index) * 6)
                .allowsHitTesting(isTop)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Action Hints

    private var actionHints: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Label("PICK", systemImage: "arrow.left")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.noRed.opacity(0.7))
                Spacer()
                Label("ACCEPT", systemImage: "arrow.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.yesGreen.opacity(0.7))
            }
            HStack(spacing: 0) {
                Label("ESCALATE", systemImage: "arrow.up")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.escalateOrange.opacity(0.8))
                Spacer()
                Label("SKIP", systemImage: "arrow.down")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.skipGray.opacity(0.8))
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 12)
        .opacity(viewModel.isAttributionWritesLocked ? 0.35 : 1)
    }

    private func writesLockedBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(Color.undoAmber.opacity(0.9))

            VStack(alignment: .leading, spacing: 2) {
                Text("Read-only mode")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.undoAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.undoAmber.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Undo Banner

    private func undoBanner(_ action: CardTriageViewModel.TriageAction) -> some View {
        Button {
            Task { await viewModel.undo() }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                    Text("Undo \(action.label)")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                if let requestId = action.requestId {
                    Text("req \(requestId)")
                        .font(.caption2)
                        .foregroundStyle(.black.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.undoAmber, in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(.bottom, 16)
    }

    // MARK: - Empty / Error

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.yesGreen.opacity(0.6))
            Text("All caught up")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("No pending triage items.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Refresh") {
                Task { await viewModel.loadQueue() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.yesGreen)
            .padding(.top, 4)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 60)
            .onTapGesture { viewModel.error = nil }
    }

    private func runSmokeSwipes() async {
        // Retry queue loading to handle race with .task loadQueue
        var retries = 0
        while viewModel.queue.isEmpty && retries < 5 {
            if !viewModel.isLoading {
                await viewModel.loadQueue()
            }
            if viewModel.queue.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                retries += 1
            }
        }

        guard !viewModel.queue.isEmpty else {
            TriageSmokeAutomation.logger.log("SMOKE_EVENT TRIAGE_EMPTY retries=\(retries, privacy: .public)")
            NotificationCenter.default.post(name: TriageSmokeAutomation.triageDoneNotification, object: nil)
            return
        }

        let targetIds = TriageSmokeAutomation.targetInteractionIds
        if !targetIds.isEmpty {
            let joinedTargets = targetIds.sorted().joined(separator: ",")
            TriageSmokeAutomation.logger.log(
                "SMOKE_EVENT TRIAGE_TARGET_IDS count=\(targetIds.count, privacy: .public) ids=\(joinedTargets, privacy: .public)"
            )
        }

        func pickSmokeCard() -> CardItem? {
            guard !viewModel.queue.isEmpty else { return nil }
            if !targetIds.isEmpty,
               let matched = viewModel.queue.first(where: { targetIds.contains($0.interactionId) }) {
                return matched
            }
            if let withProject = viewModel.queue.first(where: { $0.projectId != nil }) {
                return withProject
            }
            return viewModel.queue.first
        }

        guard let card = pickSmokeCard() else {
            TriageSmokeAutomation.logger.log("SMOKE_EVENT TRIAGE_EMPTY_AFTER_PICK")
            NotificationCenter.default.post(name: TriageSmokeAutomation.triageDoneNotification, object: nil)
            return
        }

        let eventAt = card.eventDate?.ISO8601Format() ?? "missing"
        TriageSmokeAutomation.logger.log(
            "SMOKE_EVENT TRIAGE_TARGET queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public) event_at=\(eventAt, privacy: .public)"
        )

        if let projectId = card.projectId, !projectId.isEmpty {
            TriageSmokeAutomation.logger.log(
                "SMOKE_EVENT TRIAGE_RESOLVE queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public) project=\(projectId, privacy: .public)"
            )
            viewModel.recordPickTime()
            await viewModel.resolve(card, to: projectId, notes: "smoke")
        } else {
            TriageSmokeAutomation.logger.log(
                "SMOKE_EVENT TRIAGE_DISMISS queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public)"
            )
            await viewModel.dismiss(card, reason: "smoke", notes: "smoke")
        }

        if viewModel.isAttributionWritesLocked, let banner = viewModel.attributionWritesLockedBannerText {
            TriageSmokeAutomation.logger.log(
                "SMOKE_EVENT TRIAGE_WRITE_LOCKED banner=\(banner, privacy: .public)"
            )
        } else if viewModel.canUndo {
            if TriageSmokeAutomation.shouldKeepUndoBanner {
                TriageSmokeAutomation.logger.log(
                    "SMOKE_EVENT TRIAGE_UNDO_AVAILABLE queue=\(card.queueId, privacy: .public)"
                )
            } else {
                TriageSmokeAutomation.logger.log(
                    "SMOKE_EVENT TRIAGE_UNDO_START queue=\(card.queueId, privacy: .public)"
                )
                try? await Task.sleep(for: .milliseconds(800))
                await viewModel.undo()
                try? await Task.sleep(for: .milliseconds(600))
            }
        }

        TriageSmokeAutomation.logger.log("SMOKE_EVENT TRIAGE_DONE remaining=\(viewModel.queue.count, privacy: .public)")
        NotificationCenter.default.post(name: TriageSmokeAutomation.triageDoneNotification, object: nil)
    }

    private enum PickerMode {
        case project
        case commentOnly
    }
}

// MARK: - SwipeableTriageCard

private struct SwipeableTriageCard: View {
    let card: CardItem
    let projectName: String?
    let selectedProjectName: String?
    let isTop: Bool
    let writesLocked: Bool
    let onBlockedWrite: () -> Void
    let onConfirmLocked: () -> Void
    let onSelectSuggested: () -> Void
    let onTapEvidence: () -> Void
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void
    let onSwipeUp: () -> Void
    let onSwipeDown: () -> Void
    let onTapAnalysis: () -> Void

    @State private var offset: CGSize = .zero
    @State private var rotation: Double = 0
    @State private var showAlternatives = false
    @State private var transcriptExpanded = false

    private let horizontalSwipeThreshold: CGFloat = 100
    private let verticalSwipeThreshold: CGFloat = 90

    private enum TruthState {
        case pending
        case ready
        case blocked

        var label: String {
            switch self {
            case .pending: return "Pending"
            case .ready: return "Ready"
            case .blocked: return "Blocked"
            }
        }

        var tint: Color {
            switch self {
            case .pending: return Color.skipGray
            case .ready: return Color.commentBlue
            case .blocked: return Color.noRed
            }
        }
    }

    private var truthState: TruthState {
        if writesLocked { return .blocked }
        if selectedProjectName != nil { return .ready }
        return .pending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: contact + confidence
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.contactName)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let date = card.eventDate {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                confidenceBadge
            }

            // Reason codes
            if !card.reasonCodes.isEmpty {
                reasonCodesRow
            }

            // Transcript (tap to expand/collapse)
            Text(card.transcriptSegment)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(transcriptExpanded ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { transcriptExpanded.toggle() }
                .animation(.easeInOut(duration: 0.2), value: transcriptExpanded)

            // Evidence anchors
            if !card.evidenceAnchors.isEmpty {
                evidenceSection
            }

            Divider().background(Color.cardStroke)

            truthSurfaceControls

            // Collapsible alternatives
            if !card.candidates.isEmpty {
                alternativesSection
            }

            // Analysis tap target
            Button {
                onTapAnalysis()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                    Text("Analysis")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundStyle(Color.commentBlue.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.commentBlue.opacity(0.1), in: Capsule())
            }
        }
        .padding(16)
        .background(Color.cardFace, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(swipeIndicatorColor, lineWidth: swipeIndicatorOpacity > 0 ? 2 : 1)
        )
        .overlay(alignment: .topLeading) {
            if offset.width < -40 {
                swipeLabel("PICK", icon: "arrow.left.arrow.right", color: .noRed)
                    .padding(16)
                    .opacity(min(1, Double(-offset.width - 40) / 60))
            }
        }
        .overlay(alignment: .topTrailing) {
            if offset.width > 40 {
                swipeLabel("ACCEPT", icon: "checkmark", color: .yesGreen)
                    .padding(16)
                    .opacity(min(1, Double(offset.width - 40) / 60))
            }
        }
        .overlay(alignment: .top) {
            if offset.height < -40 {
                swipeLabel("ESCALATE", icon: "exclamationmark.triangle", color: .escalateOrange)
                    .padding(.top, 16)
                    .opacity(min(1, Double(-offset.height - 40) / 60))
            }
        }
        .overlay(alignment: .bottom) {
            if offset.height > 40 {
                swipeLabel("SKIP", icon: "arrow.down.to.line", color: .skipGray)
                    .padding(.bottom, 16)
                    .opacity(min(1, Double(offset.height - 40) / 60))
            }
        }
        .offset(x: offset.width, y: offset.height)
        .rotationEffect(.degrees(rotation))
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard isTop else { return }
                    guard !writesLocked else { return }
                    offset = value.translation
                    rotation = Double(value.translation.width / 20)
                }
                .onEnded { value in
                    guard isTop else { return }
                    if writesLocked {
                        if value.translation.height > verticalSwipeThreshold,
                           abs(value.translation.height) > abs(value.translation.width) {
                            snapBack()
                            onSwipeDown()
                            return
                        }

                        if value.translation.width > horizontalSwipeThreshold
                            || value.translation.width < -horizontalSwipeThreshold
                            || value.translation.height < -verticalSwipeThreshold
                        {
                            snapBack()
                            onBlockedWrite()
                            return
                        }

                        snapBack()
                        return
                    }
                    if value.translation.width > horizontalSwipeThreshold,
                       abs(value.translation.width) >= abs(value.translation.height) {
                        if truthState == .ready {
                            swipeAway(direction: .right)
                        } else {
                            snapBack()
                            onConfirmLocked()
                        }
                    } else if value.translation.width < -horizontalSwipeThreshold,
                              abs(value.translation.width) >= abs(value.translation.height) {
                        swipeAway(direction: .left)
                    } else if value.translation.height < -verticalSwipeThreshold,
                              abs(value.translation.height) > abs(value.translation.width) {
                        // UP: snap back then open escalation sheet
                        snapBack()
                        onSwipeUp()
                    } else if value.translation.height > verticalSwipeThreshold,
                              abs(value.translation.height) > abs(value.translation.width) {
                        // DOWN: skip — snap back and reorder
                        snapBack()
                        onSwipeDown()
                    } else {
                        snapBack()
                    }
                }
        )
        .animation(.interactiveSpring(response: 0.4, dampingFraction: 0.7), value: offset)
    }

    // MARK: - Card Sections

    private var truthSurfaceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                chip(label: truthState.label, tint: truthState.tint)

                Button {
                    onTapEvidence()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 10))
                        Text("Evidence")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(card.evidenceAnchors.count)")
                            .font(.system(size: 11, weight: .bold))
                        if let date = card.eventDate {
                            Text(date, style: .relative)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.chipBg, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                if let name = projectName {
                    Button {
                        onSelectSuggested()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cpu")
                                .font(.system(size: 10))
                            Text("Suggested")
                                .font(.system(size: 11, weight: .semibold))
                            Text(name)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.yesGreen.opacity(0.25), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(writesLocked)
                    .opacity(writesLocked ? 0.6 : 1)
                }
            }

            HStack(spacing: 8) {
                Button {
                    if writesLocked {
                        onBlockedWrite()
                    } else {
                        onSwipeLeft()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.caption)
                        Text(selectedProjectName == nil ? "Pick project" : "Change project")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.noRed.opacity(0.35), in: Capsule())
                }
                .buttonStyle(.plain)
                .opacity(writesLocked ? 0.6 : 1)

                Button {
                    if writesLocked {
                        onBlockedWrite()
                    } else if truthState == .ready {
                        onSwipeRight()
                    } else {
                        onConfirmLocked()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: truthState == .ready ? "checkmark.circle.fill" : "lock.fill")
                            .font(.caption)
                        Text("Confirm")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.yesGreen.opacity(truthState == .ready ? 0.85 : 0.20), in: Capsule())
                }
                .buttonStyle(.plain)
                .opacity(truthState == .ready ? 1 : 0.8)

                Spacer()

                if let selectedProjectName {
                    Text(selectedProjectName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Pick required — confirm locked")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chip(label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.chipBg, in: Capsule())
    }

    private var reasonCodesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(card.reasonCodes, id: \.self) { code in
                    Text(formatReasonCode(code))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(reasonCodeColor(code))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(reasonCodeColor(code).opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(card.evidenceAnchors.prefix(4).enumerated()), id: \.offset) { _, anchor in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.commentBlue.opacity(0.5))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(anchor.quote ?? anchor.text ?? "")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                        if let matchType = anchor.matchType {
                            Text(matchType)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color.chipBg.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var alternativesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAlternatives.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAlternatives ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text("\(card.candidates.count) alternative\(card.candidates.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
            }

            if showAlternatives {
                HStack(spacing: 6) {
                    ForEach(card.candidates.prefix(4), id: \.projectId) { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                            if let tags = candidate.evidenceTags, !tags.isEmpty {
                                Text(tags.prefix(2).joined(separator: ", "))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.chipBg, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private var confidenceBadge: some View {
        let pct = Int(card.confidence * 100)
        let color: Color = pct >= 70 ? .yesGreen : pct >= 40 ? .undoAmber : .noRed
        return Text("\(pct)%")
            .font(.caption)
            .fontWeight(.bold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var swipeIndicatorColor: Color {
        if offset.width > 40 { return Color.yesGreen.opacity(swipeIndicatorOpacity) }
        if offset.width < -40 { return Color.noRed.opacity(swipeIndicatorOpacity) }
        if offset.height < -40 { return Color.escalateOrange.opacity(swipeIndicatorOpacity) }
        if offset.height > 40 { return Color.skipGray.opacity(swipeIndicatorOpacity) }
        return Color.cardStroke
    }

    private var swipeIndicatorOpacity: Double {
        let magnitude = max(abs(offset.width), abs(offset.height))
        guard magnitude > 40 else { return 0 }
        return min(1, Double(magnitude - 40) / 60)
    }

    private func swipeLabel(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.title2)
            .fontWeight(.black)
            .foregroundStyle(color)
    }

    private func swipeAway(direction: SwipeDirection) {
        let offscreenX: CGFloat
        let offscreenY: CGFloat
        switch direction {
        case .right:
            offscreenX = 500
            offscreenY = 0
        case .left:
            offscreenX = -500
            offscreenY = 0
        }
        withAnimation(.easeIn(duration: 0.25)) {
            offset = CGSize(width: offscreenX, height: offscreenY)
            rotation = direction == .right ? 15 : -15
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            offset = .zero
            rotation = 0
            switch direction {
            case .right: onSwipeRight()
            case .left: onSwipeLeft()
            }
        }
    }

    private func snapBack() {
        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.8)) {
            offset = .zero
            rotation = 0
        }
    }

    private func formatReasonCode(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: " ")
    }

    private func reasonCodeColor(_ code: String) -> Color {
        switch code {
        case "low_confidence": return .noRed
        case "unknown_project": return .undoAmber
        case "cross_project": return .commentBlue
        case "no_match": return .noRed
        default: return .skipGray
        }
    }

    private enum SwipeDirection { case left, right }
}

// MARK: - EscalateReasonSheet

private struct EscalateReasonSheet: View {
    @Environment(\.dismiss) private var dismiss

    let card: CardItem
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var reason = ""
    @State private var selectedPreset: String?

    private let presets = [
        "Ambiguous context",
        "Multiple projects mentioned",
        "Missing transcript data",
        "Conflicting evidence",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick Select") {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            selectedPreset = preset
                            reason = preset
                        } label: {
                            HStack {
                                Text(preset)
                                    .foregroundStyle(.white)
                                Spacer()
                                if selectedPreset == preset {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.escalateOrange)
                                }
                            }
                        }
                    }
                }
                Section("Details (required)") {
                    TextField("Why does this need escalation?", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Escalate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Escalate") {
                        dismiss()
                        onSubmit(reason)
                    }
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}

// MARK: - AnalysisDrawerSheet

private struct AnalysisDrawerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let card: CardItem
    let projectName: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Evidence matrix
                    evidenceMatrix

                    // Context pointers
                    contextPointers

                    // Full transcript
                    fullTranscript
                }
                .padding()
            }
            .background(Color.cardsBg)
            .navigationTitle("Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var evidenceMatrix: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Evidence Dimensions")

            // Confidence row
            matrixRow(
                dimension: "Confidence",
                value: "\(Int(card.confidence * 100))%",
                verdict: card.confidence >= 0.7 ? .strong : card.confidence >= 0.4 ? .moderate : .weak
            )

            // Reason codes
            if !card.reasonCodes.isEmpty {
                matrixRow(
                    dimension: "Review Reasons",
                    value: card.reasonCodes.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "),
                    verdict: .neutral
                )
            }

            // Evidence count
            matrixRow(
                dimension: "Evidence Anchors",
                value: "\(card.evidenceAnchors.count) found",
                verdict: card.evidenceAnchors.count >= 3 ? .strong : card.evidenceAnchors.count >= 1 ? .moderate : .weak
            )

            // Candidates
            matrixRow(
                dimension: "Alternatives",
                value: "\(card.candidates.count) candidate\(card.candidates.count == 1 ? "" : "s")",
                verdict: card.candidates.count <= 1 ? .strong : card.candidates.count <= 3 ? .moderate : .weak
            )

            // Keywords
            if !card.keywords.isEmpty {
                matrixRow(
                    dimension: "Keywords",
                    value: card.keywords.prefix(5).joined(separator: ", "),
                    verdict: .neutral
                )
            }
        }
        .padding(12)
        .background(Color.cardFace, in: RoundedRectangle(cornerRadius: 12))
    }

    private var contextPointers: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Context Pointers")

            // AI guess
            if let name = projectName {
                contextRow(icon: "cpu", label: "AI Guess", value: name)
            }

            contextRow(icon: "person.fill", label: "Contact", value: card.contactName)
            contextRow(icon: "doc.text", label: "Span", value: String(card.spanId.prefix(8)))
            contextRow(icon: "phone.fill", label: "Interaction", value: String(card.interactionId.prefix(8)))

            if let date = card.eventDate {
                contextRow(icon: "calendar", label: "Event Date", value: date.formatted(.dateTime.month().day().hour().minute()))
            }

            // Evidence anchors detail
            if !card.evidenceAnchors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Evidence Excerpts")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)

                    ForEach(Array(card.evidenceAnchors.enumerated()), id: \.offset) { _, anchor in
                        VStack(alignment: .leading, spacing: 2) {
                            if let quote = anchor.quote ?? anchor.text {
                                Text("\"\(quote)\"")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .italic()
                            }
                            HStack(spacing: 8) {
                                if let matchType = anchor.matchType {
                                    Text(matchType)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.commentBlue)
                                }
                                if let projectId = anchor.candidateProjectId {
                                    Text("→ \(projectId.prefix(8))")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.chipBg, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(12)
        .background(Color.cardFace, in: RoundedRectangle(cornerRadius: 12))
    }

    private var fullTranscript: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Transcript Segment")

            Text(card.transcriptSegment)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.cardFace, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.bold)
            .foregroundStyle(.white)
    }

    private enum Verdict {
        case strong, moderate, weak, neutral

        var color: Color {
            switch self {
            case .strong: return .yesGreen
            case .moderate: return .undoAmber
            case .weak: return .noRed
            case .neutral: return .skipGray
            }
        }

        var icon: String {
            switch self {
            case .strong: return "checkmark.circle.fill"
            case .moderate: return "minus.circle.fill"
            case .weak: return "xmark.circle.fill"
            case .neutral: return "info.circle.fill"
            }
        }
    }

    private func matrixRow(dimension: String, value: String, verdict: Verdict) -> some View {
        HStack {
            Image(systemName: verdict.icon)
                .font(.system(size: 11))
                .foregroundStyle(verdict.color)
            Text(dimension)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
        }
    }

    private func contextRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

// MARK: - EvidenceTokenSheet

private struct EvidenceTokenSheet: View {
    @Environment(\.dismiss) private var dismiss
    let card: CardItem

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if card.evidenceAnchors.isEmpty {
                        emptyState
                    } else {
                        anchorsList
                    }
                }
                .padding()
            }
            .background(Color.cardsBg)
            .navigationTitle("Evidence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.contactName)
                .font(.headline)
                .foregroundStyle(.white)
            if let date = card.eventDate {
                Text(date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("interaction: \(card.interactionId)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(card.transcriptSegment)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(6)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No evidence tokens")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("This item has 0 evidence anchors. That’s a pipeline gap: treat the suggestion as low confidence and rely on your own context.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.cardFace, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cardStroke, lineWidth: 1)
        )
    }

    private var anchorsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(card.evidenceAnchors.enumerated()), id: \.offset) { _, anchor in
                VStack(alignment: .leading, spacing: 6) {
                    Text(anchor.quote ?? anchor.text ?? "—")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if let matchType = anchor.matchType {
                            Label(matchType, systemImage: "tag")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let candidateProjectId = anchor.candidateProjectId {
                            Text("candidate: \(candidateProjectId)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(12)
                .background(Color.cardFace, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.cardStroke, lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - TriageCommentSheet

private struct TriageCommentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let card: CardItem
    let suggestedProjectName: String?
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                if let suggestedProjectName {
                    Section("Resolve Target") {
                        Text(suggestedProjectName)
                            .foregroundStyle(.white)
                    }
                } else {
                    Section("Resolve Target") {
                        Text("No AI guess. Pick project after comment.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Comment") {
                    TextField("Add context for this resolution", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resolve") {
                        dismiss()
                        onSubmit(note)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}
