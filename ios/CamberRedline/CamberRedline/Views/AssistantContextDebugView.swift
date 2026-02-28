import SwiftUI

private extension Color {
    static let debugBg = Color.black
    static let sectionBg = Color(red: 0.082, green: 0.082, blue: 0.09)
    static let sectionBorder = Color(red: 0.165, green: 0.165, blue: 0.18)
    static let accentGreen = Color(red: 0.188, green: 0.82, blue: 0.345)
    static let accentAmber = Color(red: 1.0, green: 0.624, blue: 0.04)
    static let accentRed = Color(red: 1.0, green: 0.231, blue: 0.188)
}

struct AssistantContextDebugView: View {
    @State private var packet: AssistantContextPacket?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if isLoading {
                        ProgressView("Fetching context...")
                            .tint(.white)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else if let error {
                        errorCard(error)
                    } else if let packet {
                        headerCard(packet)
                        pipelineHealthCard(packet.pipelineHealth)
                        topProjectsCard(packet.topProjects)
                        whoNeedsYouCard(packet.whoNeedsYou)
                        recentCallsCard(packet.recentActivity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.debugBg)
            .navigationTitle("Context Packet")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            packet = try await BootstrapService.shared.fetchAssistantContext()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Cards

    private func headerCard(_ p: AssistantContextPacket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Assistant Context")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(p.functionVersion ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                stat("Latency", "\(p.ms ?? 0)ms")
                stat("Generated", timeAgo(p.generatedAt))
            }
        }
        .padding(12)
        .background(Color.sectionBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.sectionBorder, lineWidth: 1)
        )
    }

    private func pipelineHealthCard(_ items: [PipelineCapability]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pipeline Health")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(items) { item in
                HStack {
                    Circle()
                        .fill(stalenessColor(item.hoursStale))
                        .frame(width: 8, height: 8)
                    Text(item.capability)
                        .font(.caption)
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(item.total ?? 0) rows")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(item.hoursStale ?? "?")h")
                        .font(.caption2)
                        .foregroundStyle(stalenessColor(item.hoursStale))
                }
            }
        }
        .padding(12)
        .background(Color.sectionBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.sectionBorder, lineWidth: 1)
        )
    }

    private func topProjectsCard(_ projects: [ProjectSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Projects (7d)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(projects.prefix(8)) { proj in
                HStack(spacing: 8) {
                    riskDot(proj.riskFlag)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(proj.projectName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                        HStack(spacing: 6) {
                            miniStat("\(proj.interactions7d ?? 0) calls")
                            miniStat("\(proj.activeJournalClaims ?? 0) claims")
                            miniStat("\(proj.openLoops ?? 0) loops")
                            if (proj.pendingReviews ?? 0) > 0 {
                                miniStat("\(proj.pendingReviews!) reviews", tint: Color.accentAmber)
                            }
                        }
                    }
                    Spacer()
                    if let phase = proj.phase {
                        Text(phase)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.sectionBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.sectionBorder, lineWidth: 1)
        )
    }

    private func whoNeedsYouCard(_ signals: [PeopleSignal]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who Needs You Today")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if signals.isEmpty {
                Text("No urgent people signals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(signals.prefix(5)) { signal in
                    HStack(alignment: .top, spacing: 8) {
                        categoryIcon(signal.category)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(signal.project)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.white)
                                Spacer()
                                Text("\(signal.hoursAgo)h ago")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(signal.detail)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.sectionBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.sectionBorder, lineWidth: 1)
        )
    }

    private func recentCallsCard(_ activity: RecentActivity?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Calls")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(activity?.calls24h ?? 0) in 24h")
                    .font(.caption2)
                    .foregroundStyle(Color.accentGreen)
            }

            if let calls = activity?.latestCalls, !calls.isEmpty {
                ForEach(calls) { call in
                    HStack {
                        Text(call.otherPartyName ?? "Unknown")
                            .font(.caption)
                            .foregroundStyle(.white)
                        Spacer()
                        Text(call.channel ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.sectionBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.sectionBorder, lineWidth: 1)
        )
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(Color.accentRed)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await load() } }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentRed)
        }
        .padding(20)
    }

    // MARK: - Helpers

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
        }
    }

    private func miniStat(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
    }

    private func stalenessColor(_ hoursStr: String?) -> Color {
        guard let str = hoursStr, let hours = Double(str) else { return .secondary }
        if hours < 1 { return Color.accentGreen }
        if hours < 6 { return Color.accentAmber }
        return Color.accentRed
    }

    private func riskDot(_ flag: String?) -> some View {
        let color: Color = switch flag {
        case "high_open_loops", "elevated_striking": Color.accentRed
        case "stale_project": Color.accentAmber
        default: Color.accentGreen
        }
        return Circle().fill(color).frame(width: 6, height: 6)
    }

    private func categoryIcon(_ category: String) -> some View {
        let icon: String = switch category {
        case "burnout": "flame"
        case "promise": "handshake"
        case "livelihood": "dollarsign.circle"
        case "safety": "exclamationmark.shield"
        default: "person.circle"
        }
        return Image(systemName: icon)
            .font(.caption)
            .foregroundStyle(Color.accentAmber)
            .frame(width: 16)
    }

    private func timeAgo(_ isoString: String?) -> String {
        guard let str = isoString else { return "?" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: str) else { return str }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}
