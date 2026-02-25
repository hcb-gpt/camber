import SwiftUI

private extension Color {
    static let appBg = Color.black
    static let cardBg = Color(hex: "#151517")
    static let cardBorder = Color(hex: "#2A2A2E")
    static let chipBg = Color(hex: "#252528")
    static let aiBg = Color(hex: "#1B2A46")
    static let aiBorder = Color(hex: "#4A90D9")
    static let spanBg = Color(hex: "#1C2A1E")
    static let spanBorder = Color(hex: "#2EA043")
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
    @State private var expandedCallIDs: Set<String> = []
    @State private var selectedSpanForAction: TriageSpan?
    @State private var showingSpanActions = false
    @State private var showingProjectPicker = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.appBg.ignoresSafeArea()

                if viewModel.isLoading && viewModel.calls.isEmpty {
                    ProgressView("Loading triage calls…")
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
                                    isExpanded: expandedCallIDs.contains(call.id),
                                    projectName: viewModel.projectName(for:),
                                    isResolving: viewModel.isResolving(queueId:),
                                    onToggle: { toggleExpanded(callID: call.id) },
                                    onSpanLongPress: { span in
                                        showSpanActions(for: span)
                                    }
                                )
                                .onAppear {
                                    Task {
                                        await viewModel.loadMoreIfNeeded(currentCall: call)
                                    }
                                }
                            }

                            if viewModel.isLoadingMore {
                                ProgressView("Loading more calls…")
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
                        expandedCallIDs = expandedCallIDs.intersection(Set(viewModel.calls.map(\.id)))
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
            .confirmationDialog(
                "Span attribution",
                isPresented: $showingSpanActions,
                titleVisibility: .visible
            ) {
                if let span = selectedSpanForAction,
                   let aiProjectId = span.aiGuessProjectId
                {
                    let aiName = viewModel.projectName(for: aiProjectId) ?? "AI suggestion"
                    Button("Confirm \(aiName)") {
                        Task {
                            await viewModel.confirmAI(for: span)
                            selectedSpanForAction = nil
                        }
                    }
                }

                Button("Change Project…") {
                    showingProjectPicker = true
                }
            } message: {
                if let span = selectedSpanForAction {
                    Text(span.transcriptSegment)
                }
            }
            .sheet(isPresented: $showingProjectPicker, onDismiss: {
                selectedSpanForAction = nil
            }) {
                if let span = selectedSpanForAction {
                    ProjectPickerSheet(
                        projects: viewModel.projects,
                        recommendedProjectID: span.aiGuessProjectId,
                        onSelect: { project in
                            Task {
                                await viewModel.assignProject(for: span, projectId: project.id)
                                selectedSpanForAction = nil
                            }
                        }
                    )
                } else {
                    Text("No span selected.")
                        .padding()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var summaryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Project-Span Review")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("One card per call · tap to expand")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(viewModel.calls.count) calls")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text("\(viewModel.totalPending) spans")
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
            Text("No pending project-span attributions.")
                .font(.headline)
            Button("Refresh") {
                Task { await viewModel.refreshQueue() }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
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

    private func toggleExpanded(callID: String) {
        if expandedCallIDs.contains(callID) {
            expandedCallIDs.remove(callID)
        } else {
            expandedCallIDs.insert(callID)
        }
    }

    private func showSpanActions(for span: TriageSpan) {
        guard !viewModel.isResolving(queueId: span.queueId) else { return }
        selectedSpanForAction = span

        if span.aiGuessProjectId == nil {
            showingProjectPicker = true
            return
        }

        showingSpanActions = true
    }
}

private struct TriageCallCard: View {
    let call: TriageCall
    let isExpanded: Bool
    let projectName: (String?) -> String?
    let isResolving: (String) -> Bool
    let onToggle: () -> Void
    let onSpanLongPress: (TriageSpan) -> Void

    private static let absoluteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var relativeDateLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: call.eventDate, relativeTo: .now)
    }

    private var absoluteDateLabel: String {
        Self.absoluteDateFormatter.string(from: call.eventDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(call.contactName)
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text(absoluteDateLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let summary = call.humanSummary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(relativeDateLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("\(call.spans.count) spans")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.chipBg, in: Capsule())

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                SegmentedTranscriptView(
                    transcript: call.fullTranscript,
                    spans: call.spans,
                    projectName: projectName,
                    isResolving: isResolving,
                    onSpanLongPress: onSpanLongPress
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Project spans")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(call.spans) { span in
                        ProjectSpanRow(
                            span: span,
                            projectName: projectName(span.aiGuessProjectId),
                            isResolving: isResolving(span.queueId)
                        )
                        .onLongPressGesture(minimumDuration: 0.45) {
                            onSpanLongPress(span)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
    }
}

private struct SegmentedTranscriptView: View {
    let transcript: String
    let spans: [TriageSpan]
    let projectName: (String?) -> String?
    let isResolving: (String) -> Bool
    let onSpanLongPress: (TriageSpan) -> Void

    private var blocks: [TranscriptBlock] {
        TranscriptBlockBuilder.makeBlocks(
            transcript: transcript,
            spans: spans
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full transcript")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if transcript.isEmpty {
                Text("Transcript unavailable for this call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(blocks) { block in
                        if let span = block.span {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(projectName(span.aiGuessProjectId) ?? "Needs project")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.aiBg, in: Capsule())
                                        .overlay(
                                            Capsule()
                                                .stroke(Color.aiBorder.opacity(0.7), lineWidth: 1)
                                        )

                                    if isResolving(span.queueId) {
                                        ProgressView()
                                            .tint(.white)
                                            .scaleEffect(0.75)
                                    }

                                    Spacer(minLength: 0)

                                    Text("\(Int(span.confidence * 100))%")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Text(block.text)
                                    .font(.caption)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(.white)
                            }
                            .padding(10)
                            .background(Color.spanBg, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.spanBorder.opacity(0.8), lineWidth: 1)
                            )
                            .onLongPressGesture(minimumDuration: 0.45) {
                                onSpanLongPress(span)
                            }
                        } else {
                            Text(block.text)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundStyle(Color(white: 0.72))
                        }
                    }
                }
            }
        }
    }
}

private struct ProjectSpanRow: View {
    let span: TriageSpan
    let projectName: String?
    let isResolving: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(projectName ?? "Choose project")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.chipBg, in: Capsule())

                if isResolving {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.75)
                }

                Spacer(minLength: 0)

                Text("Long press")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(span.transcriptSegment)
                .font(.caption2)
                .fontDesign(.monospaced)
                .foregroundStyle(Color(white: 0.74))
                .lineLimit(4)

            if !span.reasonCodes.isEmpty {
                Text(span.reasonCodes.joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.chipBg, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ProjectPickerSheet: View {
    let projects: [ReviewProject]
    let recommendedProjectID: String?
    let onSelect: (ReviewProject) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredProjects: [ReviewProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects }
        return projects.filter { project in
            project.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredProjects) { project in
                Button {
                    onSelect(project)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                                .foregroundStyle(.white)
                            if project.id == recommendedProjectID {
                                Text("AI suggestion")
                                    .font(.caption2)
                                    .foregroundStyle(Color.blue)
                            }
                        }

                        Spacer()

                        if project.id == recommendedProjectID {
                            Image(systemName: "sparkles")
                                .foregroundStyle(Color.blue)
                        }
                    }
                }
                .listRowBackground(Color.cardBg)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBg.ignoresSafeArea())
            .searchable(text: $searchText, prompt: "Find project")
            .navigationTitle("Choose Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct TranscriptBlock: Identifiable {
    let id: String
    let text: String
    let span: TriageSpan?
}

private enum TranscriptBlockBuilder {
    static func makeBlocks(transcript: String, spans: [TriageSpan]) -> [TranscriptBlock] {
        guard !transcript.isEmpty else { return [] }
        let source = transcript as NSString

        var matches: [(range: NSRange, span: TriageSpan)] = []
        var occupiedRanges: [NSRange] = []

        for span in spans {
            let needle = span.transcriptSegment
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard needle.count >= 8 else { continue }

            var searchRange = NSRange(location: 0, length: source.length)
            var selectedRange = NSRange(location: NSNotFound, length: 0)

            while searchRange.length > 0 {
                let candidate = source.range(
                    of: needle,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                if candidate.location == NSNotFound {
                    break
                }
                let overlaps = occupiedRanges.contains { usedRange in
                    NSIntersectionRange(usedRange, candidate).length > 0
                }
                if !overlaps {
                    selectedRange = candidate
                    break
                }

                let nextLocation = candidate.location + max(candidate.length, 1)
                guard nextLocation < source.length else { break }
                searchRange = NSRange(
                    location: nextLocation,
                    length: source.length - nextLocation
                )
            }

            if selectedRange.location != NSNotFound {
                matches.append((selectedRange, span))
                occupiedRanges.append(selectedRange)
            }
        }

        matches.sort { lhs, rhs in
            lhs.range.location < rhs.range.location
        }

        if matches.isEmpty {
            return [TranscriptBlock(id: "plain-full", text: transcript, span: nil)]
        }

        var blocks: [TranscriptBlock] = []
        var cursor = 0
        var plainIndex = 0

        for match in matches {
            if match.range.location > cursor {
                let plainRange = NSRange(
                    location: cursor,
                    length: match.range.location - cursor
                )
                let plainText = source.substring(with: plainRange)
                if !plainText.isEmpty {
                    blocks.append(
                        TranscriptBlock(
                            id: "plain-\(plainIndex)",
                            text: plainText,
                            span: nil
                        )
                    )
                    plainIndex += 1
                }
            }

            let highlightedText = source.substring(with: match.range)
            blocks.append(
                TranscriptBlock(
                    id: "span-\(match.span.queueId)",
                    text: highlightedText,
                    span: match.span
                )
            )
            cursor = match.range.location + match.range.length
        }

        if cursor < source.length {
            let tailRange = NSRange(location: cursor, length: source.length - cursor)
            let tailText = source.substring(with: tailRange)
            if !tailText.isEmpty {
                blocks.append(
                    TranscriptBlock(
                        id: "plain-tail-\(plainIndex)",
                        text: tailText,
                        span: nil
                    )
                )
            }
        }

        return blocks
    }
}

#Preview {
    TriageView()
}
