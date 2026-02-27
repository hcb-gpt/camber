import SwiftUI

struct SyncStatusView: View {
    @State private var heartbeats: [PipelineHeartbeat] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var refreshTimer: Timer?

    private let bgColor = Color(white: 0.08)

    var body: some View {
        NavigationStack {
            ZStack {
                bgColor.ignoresSafeArea()

                if isLoading && heartbeats.isEmpty {
                    ProgressView()
                        .tint(.white)
                } else if let errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if heartbeats.isEmpty {
                    Text("No pipeline data")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(sortedHeartbeats) { beat in
                            HeartbeatRow(heartbeat: beat)
                                .listRowBackground(Color(white: 0.06))
                                .listRowSeparatorTint(Color(white: 0.13))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Pipeline Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(white: 0.06), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task {
            await loadHeartbeat()
        }
        .onAppear {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                Task { @MainActor in
                    await loadHeartbeat()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private var sortedHeartbeats: [PipelineHeartbeat] {
        heartbeats.sorted { a, b in
            let orderMap: [String: Int] = ["calls": 0, "sms": 1]
            let aOrder = orderMap[a.pipeline.lowercased()] ?? 99
            let bOrder = orderMap[b.pipeline.lowercased()] ?? 99
            return aOrder < bOrder
        }
    }

    private func loadHeartbeat() async {
        do {
            heartbeats = try await SupabaseService.shared.fetchPipelineHeartbeat()
            errorMessage = nil
        } catch {
            if heartbeats.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }
}

// MARK: - HeartbeatRow

private struct HeartbeatRow: View {
    let heartbeat: PipelineHeartbeat

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(heartbeat.pipeline.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                if let date = heartbeat.lastEventAt {
                    Text(relativeTime(from: date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let minutes = heartbeat.stalenessMinutes {
                Text(stalenessLabel(minutes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        guard let minutes = heartbeat.stalenessMinutes else { return .gray }
        if minutes < 30 { return .green }
        if minutes < 120 { return .yellow }
        return .red
    }

    private func stalenessLabel(_ minutes: Double) -> String {
        if minutes < 60 {
            return "\(Int(minutes))m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return String(format: "%.1fh ago", hours)
        }
        let days = hours / 24
        return String(format: "%.1fd ago", days)
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
