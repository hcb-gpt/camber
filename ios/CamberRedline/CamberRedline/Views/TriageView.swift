import SwiftUI

private extension Color {
    static let appBg = Color.black
    static let cardBg = Color(hex: "#151517")
    static let cardBorder = Color(hex: "#2A2A2E")
    static let chipBg = Color(hex: "#252528")
    static let aiBg = Color(hex: "#1B2A46")
    static let aiBorder = Color(hex: "#4A90D9")
    static let confidenceTrack = Color(hex: "#2C2C2E")
    static let confidenceFill = Color(hex: "#30D158")
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

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.appBg.ignoresSafeArea()

                if viewModel.isLoading && viewModel.items.isEmpty {
                    ProgressView("Loading triage feed…")
                        .tint(.white)
                        .foregroundStyle(.secondary)
                } else if viewModel.items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            summaryHeader

                            ForEach(viewModel.items) { item in
                                TriageFeedCard(
                                    item: item,
                                    aiGuessName: viewModel.projectName(for: item.aiGuessProjectId)
                                )
                                .onAppear {
                                    Task {
                                        await viewModel.loadMoreIfNeeded(currentItem: item)
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
                if viewModel.items.isEmpty {
                    await viewModel.loadInitialQueue()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var summaryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Morning Manifest")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Infinite feed · newest first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(viewModel.items.count) / \(viewModel.totalPending)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
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

private struct TriageFeedCard: View {
    let item: ReviewItem
    let aiGuessName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(item.contactName ?? "Unknown Contact")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)

                Spacer()

                Text(relativeTimestamp(for: item.sortDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(item.transcriptSegment)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(Color(white: 0.75))
                .lineLimit(5)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Guess")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let aiGuessName {
                        Text(aiGuessName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.aiBg, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.aiBorder.opacity(0.7), lineWidth: 1)
                            )
                    } else {
                        Text("No suggestion")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Confidence")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.confidenceTrack)
                                .frame(width: 64, height: 5)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.confidenceFill)
                                .frame(width: max(0, 64 * CGFloat(item.confidence)), height: 5)
                        }
                        Text("\(Int(item.confidence * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let humanSummary = item.humanSummary, !humanSummary.isEmpty {
                Text(humanSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.chipBg, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
    }

    private func relativeTimestamp(for date: Date) -> String {
        guard date != .distantPast else { return "Unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

#Preview {
    TriageView()
}
