import SwiftUI
import os

private enum TriageSmokeAutomation {
    static let launchFlag = "--smoke-drive"
    static let syntheticIdsFlag = "--smoke-synthetic-ids"
    static let triageNotification = Notification.Name("camber.smoke.runTriage")
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
}

private extension Color {
    static let cardsBg = Color.black
    static let cardFace = Color(red: 0.082, green: 0.082, blue: 0.09)     // #151517
    static let surface = Color(red: 0.05, green: 0.05, blue: 0.06)
    static let cardStroke = Color(red: 0.165, green: 0.165, blue: 0.18)    // #2A2A2E
    static let chipBg = Color(red: 0.145, green: 0.145, blue: 0.157)      // #252528
    static let yesGreen = Color(red: 0.188, green: 0.82, blue: 0.345)     // #30D158
    static let noRed = Color(red: 1.0, green: 0.231, blue: 0.188)         // #FF3B30
    static let undoAmber = Color(red: 1.0, green: 0.624, blue: 0.04)      // #FF9F0A
    static let commentBlue = Color(red: 0.188, green: 0.478, blue: 1.0)   // #307AFF
}

struct AttributionTriageCardsView: View {
    @State private var viewModel = CardTriageViewModel()
    @State private var showProjectPicker = false
    @State private var pickerCard: CardItem?
    @State private var pickerMode: PickerMode = .project
    @State private var pendingResolveNote: String?
    @State private var showCommentComposer = false
    @State private var commentCard: CardItem?
    @State private var didRunSmokeTriage = false
    @State private var showAnalysis = false
    @State private var analysisCard: CardItem?

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
                                                progressBar
                                                cardStack
                                                actionHints
                                                activityRail
                                            }
                                        }
                    ...
                        // MARK: - Activity Rail
                    
                        private var activityRail: some View {
                            HStack(spacing: 20) {
                                activityItem(label: "USER", value: "ios-user", icon: "person.circle")
                                Divider().frame(height: 12).background(Color.cardStroke)
                                activityItem(label: "RATE", value: String(format: "%.1f/m", viewModel.resolvedPerMinute), icon: "gauge.medium")
                                Divider().frame(height: 12).background(Color.cardStroke)
                                activityItem(label: "HEALTH", value: "\(Int(viewModel.progressFraction * 100))%", icon: "heart.fill")
                                Spacer()
                                Text("v1.0.0-W1")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary.opacity(0.5))
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.surface, in: RoundedRectangle(cornerRadius: 0))
                            .border(Color.cardStroke, width: 0.5)
                        }
                    
                        private func activityItem(label: String, value: String, icon: String) -> some View {
                            HStack(spacing: 6) {
                                Image(systemName: icon)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(label)
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(.secondary.opacity(0.7))
                                    Text(value)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
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
                            Task { await viewModel.resolve(card, to: projectId, notes: notes) }
                        },
                        onDismissItem: {
                            Task { await viewModel.dismiss(card) }
                        },
                        onBizDevNoProject: {
                            Task {
                                await viewModel.dismiss(
                                    card,
                                    reason: "bizdev_no_project",
                                    notes: "no_project_selected"
                                )
                            }
                        },
                        showsDismissAction: pickerMode != .commentOnly
                    )
                }
            }
            .sheet(isPresented: $showCommentComposer) {
                if let card = commentCard {
                    TriageCommentSheet(
                        card: card,
                        suggestedProjectName: viewModel.projectName(for: card.projectId),
                        isEscalation: pickerMode == .escalate,
                        onCancel: {
                            commentCard = nil
                        },
                        onSubmit: { note in
                            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                            let finalNote = trimmed.isEmpty ? nil : trimmed
                            
                            if pickerMode == .escalate {
                                Task { await viewModel.dismissUndecided(card, notes: finalNote) }
                            } else if let projectId = card.projectId {
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
            .sheet(isPresented: $showAnalysis) {
                if let card = analysisCard {
                    AnalysisDrawerView(card: card, projectName: viewModel.projectName(for: card.projectId))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(viewModel.resolvedCount) done")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.queue.count) remaining")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Card Stack

    private var cardStack: some View {
        ZStack {
            ForEach(Array(viewModel.queue.prefix(3).enumerated().reversed()), id: \.element.id) { index, card in
                let isTop = index == 0
                SwipeableTriageCard(
                    card: card,
                    projectName: viewModel.projectName(for: card.projectId),
                    isTop: isTop,
                    onSwipeRight: {
                        guard let projectId = card.projectId else {
                            pickerMode = .project
                            pickerCard = card
                            showProjectPicker = true
                            return
                        }
                        Task { await viewModel.resolve(card, to: projectId) }
                    },
                    onSwipeLeft: {
                        pickerMode = .project
                        pickerCard = card
                        showProjectPicker = true
                    },
                    onSwipeUp: {
                        commentCard = card
                        pickerMode = .escalate
                        showCommentComposer = true
                    },
                    onSwipeDown: {
                        viewModel.skip(card)
                    },
                    onTapAnalysis: {
                        analysisCard = card
                        showAnalysis = true
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
                Label("NO", systemImage: "arrow.left")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.noRed.opacity(0.7))
                Spacer()
                Label("YES", systemImage: "arrow.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.yesGreen.opacity(0.7))
            }
            HStack(spacing: 0) {
                Label("LATER", systemImage: "arrow.up")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.undoAmber.opacity(0.8))
                Spacer()
                Label("NOTE", systemImage: "arrow.down")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.commentBlue.opacity(0.8))
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 12)
    }

    // MARK: - Undo Banner

    private func undoBanner(_ action: CardTriageViewModel.TriageAction) -> some View {
        Button {
            Task { await viewModel.undo() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption)
                Text("Undo \(action.label)")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.undoAmber, in: Capsule())
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
        if viewModel.queue.isEmpty {
            await viewModel.loadQueue()
        }

        guard !viewModel.queue.isEmpty else {
            TriageSmokeAutomation.logger.log("SMOKE_EVENT TRIAGE_EMPTY")
            return
        }

        let targetIds = TriageSmokeAutomation.targetInteractionIds
        var seenTargetIds = Set<String>()
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
            return viewModel.queue.first
        }

        // P0 validation: ensure BizDev / No Project action exists and is wired.
        // Show the project picker sheet long enough for the simulator smoke harness
        // to capture screenshot/video evidence.
        if let card = pickSmokeCard() {
            if targetIds.contains(card.interactionId) {
                seenTargetIds.insert(card.interactionId)
            }
            let eventAt = card.eventDate?.ISO8601Format() ?? "missing"
            TriageSmokeAutomation.logger.log(
                "SMOKE_EVENT TRIAGE_TARGET queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public) event_at=\(eventAt, privacy: .public)"
            )
            pickerMode = .project
            pickerCard = card
            showProjectPicker = true
            TriageSmokeAutomation.logger.log(
                "SMOKE_EVENT TRIAGE_OPEN_PICKER queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public)"
            )
            try? await Task.sleep(for: .seconds(5))

            TriageSmokeAutomation.logger.log(
                "SMOKE_EVENT TRIAGE_BIZDEV queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public)"
            )
            await viewModel.dismiss(card, reason: "bizdev_no_project", notes: "no_project_selected")

            showProjectPicker = false
            pickerCard = nil
            try? await Task.sleep(for: .seconds(1))
        }

        let steps = min(6, viewModel.queue.count)
        for index in 0..<steps {
            guard let card = pickSmokeCard() else { break }
            if targetIds.contains(card.interactionId) {
                seenTargetIds.insert(card.interactionId)
            }

            let eventAt = card.eventDate?.ISO8601Format() ?? "missing"
            TriageSmokeAutomation.logger.log(
                "SMOKE_EVENT TRIAGE_TARGET queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public) event_at=\(eventAt, privacy: .public)"
            )

            switch index % 4 {
            case 0 where card.projectId != nil:
                TriageSmokeAutomation.logger.log(
                    "SMOKE_EVENT TRIAGE_RESOLVE queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public) project=\(card.projectId!, privacy: .public)"
                )
                await viewModel.resolve(card, to: card.projectId!)
            case 1:
                TriageSmokeAutomation.logger.log(
                    "SMOKE_EVENT TRIAGE_DISMISS queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public)"
                )
                await viewModel.dismiss(card)
            case 2:
                TriageSmokeAutomation.logger.log(
                    "SMOKE_EVENT TRIAGE_UNDECIDED queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public)"
                )
                await viewModel.dismissUndecided(card)
            case 3:
                TriageSmokeAutomation.logger.log(
                    "SMOKE_EVENT TRIAGE_COMMENT queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public)"
                )
                await viewModel.resolve(card, to: card.projectId ?? "", notes: "smoke-comment")
            default:
                TriageSmokeAutomation.logger.log(
                    "SMOKE_EVENT TRIAGE_DISMISS queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public)"
                )
                await viewModel.dismiss(card)
            }

            try? await Task.sleep(for: .milliseconds(1200))
        }

        if !targetIds.isEmpty {
            let remainingTargetIds = targetIds.subtracting(seenTargetIds)
            let matchedAll = remainingTargetIds.isEmpty
            let remaining = remainingTargetIds.sorted().joined(separator: ",")
            TriageSmokeAutomation.logger.log(
                "SMOKE_EVENT TRIAGE_TARGET_COVERAGE matched_all=\(matchedAll, privacy: .public) remaining=\(remaining, privacy: .public)"
            )
        }

        TriageSmokeAutomation.logger.log("SMOKE_EVENT TRIAGE_DONE remaining=\(viewModel.queue.count, privacy: .public)")
    }

    private enum PickerMode {
        case project
        case commentOnly
        case escalate
    }
}

// MARK: - SwipeableTriageCard

private struct SwipeableTriageCard: View {
    let card: CardItem
    let projectName: String?
    let isTop: Bool
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void
    let onSwipeUp: () -> Void
    let onSwipeDown: () -> Void
    let onTapAnalysis: () -> Void

    @State private var offset: CGSize = .zero
    @State private var rotation: Double = 0

    private let horizontalSwipeThreshold: CGFloat = 100
    private let verticalSwipeThreshold: CGFloat = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                
                Button {
                    onTapAnalysis()
                } label: {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(8)
                        .background(Color.chipBg, in: Circle())
                }
                
                confidenceBadge
            }

            // Transcript and Evidence
            VStack(alignment: .leading, spacing: 10) {
                Text(card.transcriptSegment)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !card.anchors.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(card.anchors.prefix(3), id: \.quote) { anchor in
                            if let quote = anchor.quote {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "quote.opening")
                                        .font(.system(size: 8))
                                        .foregroundStyle(Color.yesGreen.opacity(0.6))
                                    Text(quote)
                                        .font(.caption)
                                        .italic()
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.leading, 4)
                            }
                        }
                    }
                }
            }

            Divider().background(Color.cardStroke)

            // AI guess and Reasons
            VStack(alignment: .leading, spacing: 10) {
                if let name = projectName {
                    HStack(spacing: 8) {
                        Image(systemName: "cpu")
                            .font(.caption)
                            .foregroundStyle(Color.yesGreen.opacity(0.7))
                        Text(name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                        Spacer()
                        Text("RIGHT to confirm")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                if !card.reasonCodes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(card.reasonCodes, id: \.self) { code in
                                Text(code)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.undoAmber.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
            }

            // Alternatives (Collapsed)
            if card.candidates.count > 1 {
                let alternatives = card.candidates.filter { $0.projectId != card.projectId }
                if !alternatives.isEmpty {
                    HStack(spacing: 6) {
                        Text("ALT:")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        ForEach(alternatives.prefix(2), id: \.projectId) { alt in
                            Text(alt.name)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.chipBg, in: Capsule())
                        }
                        if alternatives.count > 2 {
                            Text("+\(alternatives.count - 2)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(Color.cardFace, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(swipeIndicatorColor, lineWidth: swipeIndicatorOpacity > 0 ? 2 : 1)
        )
        .overlay(alignment: .topLeading) {
            if offset.width < -40 {
                swipeLabel("NO", icon: "xmark", color: .noRed)
                    .padding(16)
                    .opacity(min(1, Double(-offset.width - 40) / 60))
            }
        }
        .overlay(alignment: .topTrailing) {
            if offset.width > 40 {
                swipeLabel("YES", icon: "checkmark", color: .yesGreen)
                    .padding(16)
                    .opacity(min(1, Double(offset.width - 40) / 60))
            }
        }
        .overlay(alignment: .top) {
            if offset.height < -40 {
                swipeLabel("ESCALATE", icon: "arrow.up.circle.fill", color: .noRed)
                    .padding(.top, 16)
                    .opacity(min(1, Double(-offset.height - 40) / 60))
            }
        }
        .overlay(alignment: .bottom) {
            if offset.height > 40 {
                swipeLabel("SKIP", icon: "arrow.forward.circle.fill", color: .chipBg)
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
                    offset = value.translation
                    rotation = Double(value.translation.width / 20)
                }
                .onEnded { value in
                    guard isTop else { return }
                    if value.translation.width > horizontalSwipeThreshold,
                       abs(value.translation.width) >= abs(value.translation.height) {
                        swipeAway(direction: .right)
                    } else if value.translation.width < -horizontalSwipeThreshold,
                              abs(value.translation.width) >= abs(value.translation.height) {
                        swipeAway(direction: .left)
                    } else if value.translation.height < -verticalSwipeThreshold,
                              abs(value.translation.height) > abs(value.translation.width) {
                        swipeAway(direction: .up)
                    } else if value.translation.height > verticalSwipeThreshold,
                              abs(value.translation.height) > abs(value.translation.width) {
                        swipeAway(direction: .down)
                    } else {
                        snapBack()
                    }
                }
        )
        .animation(.interactiveSpring(response: 0.4, dampingFraction: 0.7), value: offset)
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
        if offset.height < -40 { return Color.undoAmber.opacity(swipeIndicatorOpacity) }
        if offset.height > 40 { return Color.commentBlue.opacity(swipeIndicatorOpacity) }
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
        case .up:
            offscreenX = 0
            offscreenY = -700
        case .down:
            offscreenX = 0
            offscreenY = 700
        }
        withAnimation(.easeIn(duration: 0.25)) {
            offset = CGSize(width: offscreenX, height: offscreenY)
            switch direction {
            case .right:
                rotation = 15
            case .left:
                rotation = -15
            case .up, .down:
                rotation = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            offset = .zero
            rotation = 0
            switch direction {
            case .right: onSwipeRight()
            case .left: onSwipeLeft()
            case .up: onSwipeUp()
            case .down: onSwipeDown()
            }
        }
    }

    private func snapBack() {
        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.8)) {
            offset = .zero
            rotation = 0
        }
    }

    private enum SwipeDirection { case left, right, up, down }
}

private struct TriageCommentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let card: CardItem
    let suggestedProjectName: String?
    var isEscalation: Bool = false
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                if isEscalation {
                    Section("Escalation Reason") {
                        Text("This item will be moved to the manual review queue for further investigation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let suggestedProjectName {
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
                Section(isEscalation ? "Reason *" : "Comment") {
                    TextField(isEscalation ? "Why does this need escalation?" : "Add context for this resolution", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(isEscalation ? "Escalate" : "Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEscalation ? "Escalate" : "Resolve") {
                        dismiss()
                        onSubmit(note)
                    }
                    .disabled(isEscalation && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Analysis Drawer

private struct AnalysisDrawerView: View {
    @Environment(\.dismiss) private var dismiss
    let card: CardItem
    let projectName: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Summary Section
                    SectionHeader(title: "Verdict Analysis")
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Proposed Project")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(projectName ?? "None")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                        }
                        
                        HStack {
                            Text("Confidence Score")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(card.confidence * 100))%")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundStyle(card.confidence >= 0.7 ? .green : .orange)
                        }
                    }
                    .padding()
                    .background(Color.cardFace, in: RoundedRectangle(cornerRadius: 12))

                    // Evidence Matrix (Anchors)
                    if !card.anchors.isEmpty {
                        SectionHeader(title: "Evidence Matrix")
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(card.anchors, id: \.quote) { anchor in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(anchor.matchType?.uppercased() ?? "MATCH")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.chipBg, in: RoundedRectangle(cornerRadius: 4))
                                            .foregroundStyle(.green)
                                        Spacer()
                                    }
                                    
                                    Text(anchor.quote ?? "")
                                        .font(.subheadline)
                                        .italic()
                                        .foregroundStyle(.white.opacity(0.9))
                                    
                                    if let context = anchor.text {
                                        Text(context)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding()
                                .background(Color.cardFace, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.cardStroke, lineWidth: 1)
                                )
                            }
                        }
                    }

                    // Surrounding Context (Full Transcript)
                    if let fullTranscript = card.fullTranscript {
                        SectionHeader(title: "Surrounding Context")
                        Text(fullTranscript)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding()
                            .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.cardStroke, lineWidth: 1)
                            )
                    }
                }
                .padding()
            }
            .navigationTitle("Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .background(Color.cardsBg)
        }
        .preferredColorScheme(.dark)
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.bold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(1)
    }
}
