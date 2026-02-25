import SwiftUI

// MARK: - Design Tokens

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }

    // Backgrounds
    static let appBg        = Color(hex: "#000000")
    static let cardBg       = Color(hex: "#1A1A1A")
    static let cardBorder   = Color(hex: "#2A2A2A")

    // Project buttons
    static let btnNormal    = Color(hex: "#1C1C1E")   // dark gray — NOT green
    static let btnAI        = Color(hex: "#1A2A4A")   // blue tint for AI pick
    static let btnAIBorder  = Color(hex: "#4A90D9")   // blue glow

    // Actions
    static let skipBg       = Color(hex: "#2C2C2E")
    static let noneBg       = Color(hex: "#3A1A1A")
    static let noneBorder   = Color(hex: "#FF453A")

    // Accents
    static let green        = Color(hex: "#30D158")
    static let orange       = Color(hex: "#FF9500")
    static let red          = Color(hex: "#FF453A")
    static let blue         = Color(hex: "#4A90D9")

    // Progress track
    static let progressTrack = Color(hex: "#1C1C1E")
}

// MARK: - Confidence color helper

private func confidenceColor(_ value: Double) -> Color {
    if value >= 0.70 { return .green }
    if value >= 0.40 { return .orange }
    return .red
}

// MARK: - TriageView

struct TriageView: View {
    @State private var viewModel = TriageViewModel()
    @State private var showFullTranscript = false

    private let cardTransition: AnyTransition = .asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBg.ignoresSafeArea()

            if viewModel.isLoading {
                loadingView
            } else if viewModel.currentItem == nil && !viewModel.isLoading {
                emptyState
            } else {
                mainContent
            }

            // Error banner floats above bottom buttons
            if let error = viewModel.error {
                errorBanner(error)
                    .padding(.bottom, 148)   // clear the bottom action row
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: viewModel.error)
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomActionBar
        }
        .task {
            if viewModel.items.isEmpty {
                await viewModel.loadQueue()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Main content (progress + card + grid)

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Progress bar — full width, flush to top
            progressBar
                .padding(.top, 4)

            // Streak + counter row
            statsRow
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

            // Card — ~40% of screen height
            if let item = viewModel.currentItem {
                reviewCard(item: item)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .id(item.id)
                    .transition(cardTransition)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: item.id)
                    .opacity(viewModel.isSubmitting ? 0.6 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: viewModel.isSubmitting)

                // Project grid — scrollable, fills remaining space
                ScrollView(.vertical, showsIndicators: false) {
                    projectGrid(item: item)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.progressTrack)
                    .frame(height: 3)
                Rectangle()
                    .fill(Color.green)
                    .frame(
                        width: max(0, geo.size.width * CGFloat(viewModel.progressFraction)),
                        height: 3
                    )
                    .animation(.easeInOut(duration: 0.4), value: viewModel.progressFraction)
            }
        }
        .frame(height: 3)
    }

    // MARK: - Stats Row (streak + progress counter)

    private var statsRow: some View {
        HStack(spacing: 10) {
            // Streak — show for any streak >= 1
            if viewModel.streak >= 1 {
                HStack(spacing: 4) {
                    Text("🔥")
                        .font(.caption)
                    Text("\(viewModel.streak)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.streak)
            }

            // Resolved / total
            let resolved = viewModel.resolvedCount + viewModel.dismissedCount
            Text("\(resolved) / \(viewModel.totalPending)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            Spacer()

            // Rate per minute (subtle)
            if viewModel.ratePerMinute > 0 {
                Text(String(format: "%.1f/min", viewModel.ratePerMinute))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Review Card

    private func reviewCard(item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            // Contact + span ID header
            HStack(spacing: 8) {
                Image(systemName: "phone.fill")
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.4))

                Text(item.contactName ?? "Unknown Contact")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(item.contactName != nil ? .white : Color(white: 0.45))

                Spacer()

                Text(String(item.spanId.prefix(8)))
                    .font(.caption2)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Color(white: 0.28))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().background(Color(white: 0.16))

            // Transcript text
            transcriptSection(item: item)
                .padding(.horizontal, 14)
                .padding(.top, 8)

            // Show Full / Show Less toggle
            if (item.fullTranscript ?? item.transcriptSegment).count > 280 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showFullTranscript.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(showFullTranscript ? "Show Less" : "Show Full")
                            .font(.caption)
                        Image(systemName: showFullTranscript ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(Color(white: 0.38))
                }
                .padding(.horizontal, 14)
                .padding(.top, 5)
            }

            Divider()
                .background(Color(white: 0.16))
                .padding(.top, 8)

            // AI guess + confidence
            aiRow(item: item)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            // Reason chips
            let chips = resolveChips(item: item)
            if !chips.isEmpty {
                ChipRow(items: chips)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                Spacer().frame(height: 12)
            }
        }
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Transcript Section

    private func transcriptSection(item: ReviewItem) -> some View {
        let fullText = item.transcriptSegment
        let truncated: String = {
            guard fullText.count > 280 else { return fullText }
            let endIndex = fullText.index(fullText.startIndex, offsetBy: 280)
            return String(fullText[..<endIndex]) + "…"
        }()
        let displayed = showFullTranscript ? fullText : truncated

        return Text(displayed.isEmpty ? "(No transcript)" : displayed)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color(.systemGray))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - AI Row

    private func aiRow(item: ReviewItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(Color.blue)
                    Text("AI Guess")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                let guessName = viewModel.projects
                    .first(where: { $0.id == item.aiGuessProjectId })?.name

                if let name = guessName {
                    Text(name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.btnAI, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.btnAIBorder.opacity(0.65), lineWidth: 1)
                        )
                } else {
                    Text("No suggestion")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Confidence pill
            VStack(alignment: .trailing, spacing: 4) {
                Text("Confidence")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(white: 0.14))
                            .frame(width: 64, height: 5)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(confidenceColor(item.confidence))
                            .frame(
                                width: max(0, 64 * CGFloat(item.confidence)),
                                height: 5
                            )
                    }
                    Text("\(Int(item.confidence * 100))%")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(confidenceColor(item.confidence))
                        .frame(minWidth: 30, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Project Grid

    private func projectGrid(item: ReviewItem) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
        ]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(viewModel.projects) { project in
                let isAI = project.id == item.aiGuessProjectId
                ProjectButton(
                    project: project,
                    isAISuggested: isAI,
                    isSubmitting: viewModel.isSubmitting
                ) {
                    guard !viewModel.isSubmitting else { return }
                    let selectedProjectId = project.id
                    Task { await viewModel.assignProject(projectId: selectedProjectId) }
                }
            }
        }
    }

    // MARK: - Bottom Action Bar (always visible via safeAreaInset)

    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color(white: 0.14))

            VStack(spacing: 8) {
                // SKIP + NONE
                HStack(spacing: 12) {
                    Button {
                        withAnimation { viewModel.skip() }
                    } label: {
                        Label("SKIP", systemImage: "arrow.right")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(white: 0.65))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.skipBg, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(viewModel.isSubmitting || !viewModel.hasMore)

                    Button {
                        Task { await viewModel.dismiss() }
                    } label: {
                        Label("NONE", systemImage: "xmark")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.noneBg, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(Color.noneBorder.opacity(0.55), lineWidth: 1)
                            )
                    }
                    .disabled(viewModel.isSubmitting || !viewModel.hasMore)
                }

                // Undo row — only shown if there's a last action
                if viewModel.lastAction != nil {
                    Button {
                        Task { await viewModel.undo() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.caption)
                            Text("Undo last")
                                .font(.subheadline)
                        }
                        .foregroundStyle(Color(white: 0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: viewModel.lastAction != nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .background(Color.appBg)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Color.green)
                .scaleEffect(1.4)
            Text("Loading queue…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("All done! 🎉")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            let resolved = viewModel.resolvedCount + viewModel.dismissedCount
            if resolved > 0 {
                Text("\(viewModel.resolvedCount) assigned · \(viewModel.dismissedCount) dismissed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Queue is clear for this session.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Refresh Queue") {
                Task { await viewModel.loadQueue() }
            }
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(Color.green)
            .frame(height: 48)
            .padding(.horizontal, 32)
            .background(Color.btnNormal, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.green.opacity(0.45), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .onTapGesture { viewModel.error = nil }
    }

    // MARK: - Chip Helper

    private func resolveChips(item: ReviewItem) -> [String] {
        if let kw = item.contextPayload?.keywords, !kw.isEmpty {
            return Array(kw.prefix(8))
        }
        if let rc = item.reasonCodes, !rc.isEmpty {
            return Array(rc.prefix(5))
        }
        if let r = item.reasons, !r.isEmpty {
            return Array(r.prefix(4))
        }
        return []
    }
}

// MARK: - ProjectButton

private struct ProjectButton: View {
    let project: ReviewProject
    let isAISuggested: Bool
    let isSubmitting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(isAISuggested ? "★ \(project.name)" : project.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                isAISuggested ? Color.btnAI : Color.btnNormal,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isAISuggested ? Color.btnAIBorder : Color(white: 0.2),
                        lineWidth: isAISuggested ? 1.5 : 0.5
                    )
            )
            .shadow(
                color: isAISuggested ? Color.btnAIBorder.opacity(0.35) : .clear,
                radius: 6, x: 0, y: 0
            )
            .opacity(isSubmitting ? 0.5 : 1.0)
        }
        .disabled(isSubmitting)
    }
}

// MARK: - ChipRow (reason / keyword tags)

private struct ChipRow: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { label in
                Text(label)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: "#2C2C2E"), in: Capsule())
            }
        }
    }
}

// MARK: - FlowLayout (wrapping chip layout)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                y += rowH + spacing
                x = 0
                rowH = 0
            }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

// MARK: - Preview

#Preview {
    TriageView()
}
