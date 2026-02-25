import SwiftUI

private extension Color {
    static let appBg = Color.black
    static let cardBg = Color(hex: "#151517")
    static let cardBorder = Color(hex: "#2A2A2E")
    static let transcriptBg = Color(hex: "#101014")
    static let spanBg = Color(hex: "#1B1C21")
    static let chipBg = Color(hex: "#252528")
}

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        self.init(
            red: Double((int >> 16) & 0xFF) / 255.0,
            green: Double((int >> 8) & 0xFF) / 255.0,
            blue: Double(int & 0xFF) / 255.0
        )
    }
}

struct TriageView: View {
    @State private var viewModel = TriageViewModel()
    @State private var expandedCallIds: Set<String> = []
    @State private var selectedSpan: TriageSpan?
    @State private var selectedSpanContactName = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.appBg.ignoresSafeArea()

                if viewModel.isLoading && viewModel.calls.isEmpty {
                    ProgressView("Loading triage feed…")
                        .tint(.white)
                        .foregroundStyle(.secondary)
                } else if viewModel.calls.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            summaryHeader

                            ForEach(viewModel.calls) { call in
                                TriageCallCard(
                                    call: call,
                                    isExpanded: expandedCallIds.contains(call.id),
                                    projectNameForId: { projectId in
                                        viewModel.projectName(for: projectId)
                                    },
                                    onToggleExpanded: {
                                        toggleCall(call.id)
                                    },
                                    onLongPressSpan: { span in
                                        selectedSpan = span
                                        selectedSpanContactName = call.contactName
                                    }
                                )
                                .onAppear {
                                    Task {
                                        await viewModel.loadMoreIfNeeded(currentCall: call)
                                    }
                                }
                            }

                            if viewModel.isLoadingMore {
                                ProgressView("Loading more…")
                                    .tint(.white)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 16)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .refreshable {
                        await viewModel.refreshQueue()
                    }
                }

                if let error = viewModel.error {
                    errorBanner(error)
                }
            }
            .navigationTitle("Triage")
            .task {
                if viewModel.calls.isEmpty {
                    await viewModel.loadInitialQueue()
                }
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            dialogTitle,
            isPresented: isSpanDialogPresented,
            titleVisibility: .visible
        ) {
            if let selectedSpan {
                if let currentProjectId = selectedSpan.projectId,
                   let currentName = viewModel.projectName(for: currentProjectId)
                {
                    Button("Confirm \(currentName)") {
                        applyProject(currentProjectId, to: selectedSpan)
                    }
                }

                ForEach(viewModel.projectOptions(for: selectedSpan)) { project in
                    if project.id != selectedSpan.projectId {
                        Button("Assign \(project.name)") {
                            applyProject(project.id, to: selectedSpan)
                        }
                    }
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            if let selectedSpan {
                Text("Long press detected on a project span for \(selectedSpanContactName).")
            }
        }
    }

    private var summaryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Morning Manifest")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("One card per call · tap to expand")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(viewModel.calls.count) calls")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text("\(viewModel.multiProjectCallCount) multi-project")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No pending triage items.")
                .font(.headline)
            Button("Refresh") {
                Task { await viewModel.refreshQueue() }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }

    private var isSpanDialogPresented: Binding<Bool> {
        Binding(
            get: { selectedSpan != nil },
            set: { shouldPresent in
                if !shouldPresent {
                    selectedSpan = nil
                }
            }
        )
    }

    private var dialogTitle: String {
        guard let selectedSpan else { return "Span Actions" }
        if let projectId = selectedSpan.projectId,
           let projectName = viewModel.projectName(for: projectId)
        {
            return "Confirm or change attribution (\(projectName))"
        }
        return "Confirm or change attribution"
    }

    private func applyProject(_ projectId: String, to span: TriageSpan) {
        let selected = span
        selectedSpan = nil
        Task {
            await viewModel.resolveSpan(selected, to: projectId)
        }
    }

    private func toggleCall(_ callId: String) {
        if expandedCallIds.contains(callId) {
            expandedCallIds.remove(callId)
        } else {
            expandedCallIds.insert(callId)
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
            .padding(.bottom, 14)
            .onTapGesture { viewModel.error = nil }
    }
}

private struct TriageCallCard: View {
    let call: TriageCall
    let isExpanded: Bool
    let projectNameForId: (String?) -> String?
    let onToggleExpanded: () -> Void
    let onLongPressSpan: (TriageSpan) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(call.contactName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    Text(eventTimestamp(call.eventDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    chip(text: "\(call.spans.count) spans")
                    if call.hasMultipleProjects {
                        chip(text: "multi-project", tint: Color(hex: "#3B82F6").opacity(0.25))
                    }
                    if call.isMock {
                        chip(text: "mock", tint: Color(hex: "#FB923C").opacity(0.25))
                    }
                }
            }

            if let summary = call.humanSummary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Button {
                onToggleExpanded()
            } label: {
                HStack(spacing: 6) {
                    Text(isExpanded ? "Hide Full Transcript" : "Show Full Transcript")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.chipBg, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if isExpanded {
                transcriptPanel
                spansPanel
            } else {
                compactSpansPreview
            }
        }
        .padding(12)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Full Transcript")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollView {
                Text(call.fullTranscript)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Color(white: 0.80))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(Color.transcriptBg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.cardBorder.opacity(0.7), lineWidth: 1)
            )
        }
    }

    private var spansPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Project Attribution Spans")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("Long press to confirm/change")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(call.spans) { span in
                TriageSpanRow(
                    span: span,
                    projectName: projectNameForId(span.projectId) ?? "Unassigned",
                    accentColor: accentColor(for: span.projectId),
                    onLongPress: {
                        onLongPressSpan(span)
                    }
                )
            }
        }
    }

    private var compactSpansPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(call.spans.prefix(2)) { span in
                HStack(spacing: 8) {
                    Circle()
                        .fill(accentColor(for: span.projectId))
                        .frame(width: 7, height: 7)
                    Text(projectNameForId(span.projectId) ?? "Unassigned")
                        .font(.caption2)
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(Int(span.confidence * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chip(text: String, tint: Color = Color.chipBg) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint, in: RoundedRectangle(cornerRadius: 7))
    }

    private func eventTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func accentColor(for projectId: String?) -> Color {
        guard let projectId, !projectId.isEmpty else {
            return Color(hex: "#8E8E93")
        }
        let palette: [Color] = [
            Color(hex: "#3B82F6"),
            Color(hex: "#22C55E"),
            Color(hex: "#F59E0B"),
            Color(hex: "#EF4444"),
            Color(hex: "#A855F7"),
            Color(hex: "#06B6D4"),
        ]
        let seed = projectId.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
        return palette[seed % palette.count]
    }
}

private struct TriageSpanRow: View {
    let span: TriageSpan
    let projectName: String
    let accentColor: Color
    let onLongPress: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(projectName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 7))

                Spacer()

                Text("\(Int(span.confidence * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(span.transcriptSegment)
                .font(.caption)
                .foregroundStyle(Color(white: 0.83))
                .lineLimit(nil)

            if !span.reasonCodes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(span.reasonCodes.prefix(3)), id: \.self) { reason in
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.chipBg, in: Capsule())
                    }
                }
            }
        }
        .padding(10)
        .background(Color.spanBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.cardBorder.opacity(0.8), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3)
                .padding(.vertical, 6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onLongPressGesture(minimumDuration: 0.35, perform: onLongPress)
    }
}

#Preview {
    TriageView()
}
