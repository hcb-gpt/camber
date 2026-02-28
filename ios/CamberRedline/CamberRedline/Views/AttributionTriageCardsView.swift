import SwiftUI

private extension Color {
    static let cardsBg = Color.black
    static let cardFace = Color(red: 0.082, green: 0.082, blue: 0.09)     // #151517
    static let cardStroke = Color(red: 0.165, green: 0.165, blue: 0.18)    // #2A2A2E
    static let chipBg = Color(red: 0.145, green: 0.145, blue: 0.157)      // #252528
    static let yesGreen = Color(red: 0.188, green: 0.82, blue: 0.345)     // #30D158
    static let noRed = Color(red: 1.0, green: 0.231, blue: 0.188)         // #FF3B30
    static let undoAmber = Color(red: 1.0, green: 0.624, blue: 0.04)      // #FF9F0A
    static let laterBlue = Color(red: 0.25, green: 0.52, blue: 1.0)      // #4085FF
    static let noteViolet = Color(red: 0.69, green: 0.32, blue: 1.0)     // #B052FF
}

struct AttributionTriageCardsView: View {
    @State private var viewModel = CardTriageViewModel()
    @State private var showProjectPicker = false
    @State private var pickerCard: CardItem?
    @State private var showCommentSheet = false
    @State private var commentCard: CardItem?
    @State private var commentText = ""

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
            .sheet(isPresented: $showProjectPicker) {
                if let card = pickerCard {
                    ProjectPickerSheet(
                        card: card,
                        projects: viewModel.projectOptions(for: card),
                        onSelect: { projectId in
                            Task { await viewModel.resolve(card, to: projectId) }
                        },
                        onDismissItem: {
                            Task { await viewModel.dismiss(card) }
                        }
                    )
                }
            }
            .sheet(isPresented: $showCommentSheet) {
                if let card = commentCard {
                    CommentSheet(
                        contactName: card.contactName,
                        text: $commentText,
                        onSubmit: {
                            let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            Task { await viewModel.addComment(card, comment: text) }
                            showCommentSheet = false
                        },
                        onCancel: { showCommentSheet = false }
                    )
                    .presentationDetents([.medium])
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
                            pickerCard = card
                            showProjectPicker = true
                            return
                        }
                        Task { await viewModel.resolve(card, to: projectId) }
                    },
                    onSwipeLeft: {
                        pickerCard = card
                        showProjectPicker = true
                    },
                    onSwipeUp: {
                        Task { await viewModel.markUndecided(card) }
                    },
                    onSwipeDown: {
                        commentCard = card
                        commentText = ""
                        showCommentSheet = true
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
            // Up hint
            Label("LATER", systemImage: "arrow.up")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.laterBlue.opacity(0.7))

            // Left / Right hints
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
            .padding(.horizontal, 40)

            // Down hint
            Label("NOTE", systemImage: "arrow.down")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.noteViolet.opacity(0.7))
        }
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
}

// MARK: - SwipeableTriageCard

private struct SwipeableTriageCard: View {
    let card: CardItem
    let projectName: String?
    let isTop: Bool
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void
    var onSwipeUp: (() -> Void)?
    var onSwipeDown: (() -> Void)?

    @State private var offset: CGSize = .zero
    @State private var rotation: Double = 0

    private let swipeThreshold: CGFloat = 100

    /// Which axis dominates the current drag — prevents conflicting overlays on diagonal drags.
    private var dominantAxis: DominantAxis {
        abs(offset.width) >= abs(offset.height) ? .horizontal : .vertical
    }

    private enum DominantAxis { case horizontal, vertical }

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
                confidenceBadge
            }

            // Transcript
            Text(card.transcriptSegment)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().background(Color.cardStroke)

            // AI guess
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
                    Text("Swipe \(Image(systemName: "arrow.right")) to confirm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(Color.undoAmber.opacity(0.7))
                    Text("No AI guess")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Swipe to pick project")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Candidate chips
            if !card.candidates.isEmpty {
                HStack(spacing: 6) {
                    ForEach(card.candidates.prefix(3), id: \.projectId) { candidate in
                        Text(candidate.name)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.chipBg, in: Capsule())
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
            if dominantAxis == .horizontal, offset.width < -40 {
                swipeLabel("NO", icon: "xmark", color: .noRed)
                    .padding(16)
                    .opacity(min(1, Double(-offset.width - 40) / 60))
            }
        }
        .overlay(alignment: .topTrailing) {
            if dominantAxis == .horizontal, offset.width > 40 {
                swipeLabel("YES", icon: "checkmark", color: .yesGreen)
                    .padding(16)
                    .opacity(min(1, Double(offset.width - 40) / 60))
            }
        }
        .overlay(alignment: .top) {
            if dominantAxis == .vertical, offset.height < -40 {
                swipeLabel("LATER", icon: "clock", color: .laterBlue)
                    .padding(.top, 16)
                    .opacity(min(1, Double(-offset.height - 40) / 60))
            }
        }
        .overlay(alignment: .bottom) {
            if dominantAxis == .vertical, offset.height > 40 {
                swipeLabel("NOTE", icon: "pencil.line", color: .noteViolet)
                    .padding(.bottom, 16)
                    .opacity(min(1, Double(offset.height - 40) / 60))
            }
        }
        .offset(x: offset.width, y: dominantAxis == .vertical ? offset.height : 0)
        .rotationEffect(.degrees(rotation))
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard isTop else { return }
                    offset = value.translation
                    // Only rotate on horizontal-dominant drags
                    if abs(value.translation.width) >= abs(value.translation.height) {
                        rotation = Double(value.translation.width / 20)
                    } else {
                        rotation = 0
                    }
                }
                .onEnded { value in
                    guard isTop else { return }
                    let tx = value.translation.width
                    let ty = value.translation.height

                    if abs(tx) >= abs(ty) {
                        // Horizontal dominant
                        if tx > swipeThreshold {
                            swipeAway(direction: .right)
                        } else if tx < -swipeThreshold {
                            swipeAway(direction: .left)
                        } else {
                            snapBack()
                        }
                    } else {
                        // Vertical dominant
                        if ty < -swipeThreshold {
                            swipeAway(direction: .up)
                        } else if ty > swipeThreshold {
                            swipeAway(direction: .down)
                        } else {
                            snapBack()
                        }
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
        let op = swipeIndicatorOpacity
        if dominantAxis == .horizontal {
            if offset.width > 40 { return Color.yesGreen.opacity(op) }
            if offset.width < -40 { return Color.noRed.opacity(op) }
        } else {
            if offset.height < -40 { return Color.laterBlue.opacity(op) }
            if offset.height > 40 { return Color.noteViolet.opacity(op) }
        }
        return Color.cardStroke
    }

    private var swipeIndicatorOpacity: Double {
        let magnitude = dominantAxis == .horizontal
            ? abs(offset.width)
            : abs(offset.height)
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
        withAnimation(.easeIn(duration: 0.25)) {
            switch direction {
            case .right:
                offset = CGSize(width: 500, height: 0)
                rotation = 15
            case .left:
                offset = CGSize(width: -500, height: 0)
                rotation = -15
            case .up:
                offset = CGSize(width: 0, height: -800)
                rotation = 0
            case .down:
                offset = CGSize(width: 0, height: 800)
                rotation = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            offset = .zero
            rotation = 0
            switch direction {
            case .right: onSwipeRight()
            case .left: onSwipeLeft()
            case .up: onSwipeUp?()
            case .down: onSwipeDown?()
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

// MARK: - Comment Sheet

private struct CommentSheet: View {
    let contactName: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Add note for \(contactName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Your comment...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.cardFace, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.cardStroke, lineWidth: 1)
                    )
                    .lineLimit(3...8)
                    .focused($isFocused)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .background(Color.cardsBg.ignoresSafeArea())
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSubmit)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.noteViolet)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationBackground(Color.cardsBg)
        .onAppear { isFocused = true }
    }
}
