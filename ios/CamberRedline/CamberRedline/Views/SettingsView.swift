import SwiftUI

struct SettingsView: View {
    var contactListViewModel: ContactListViewModel

    @State private var showResetConfirmation = false

    private let bgColor = Color(white: 0.06)

    var body: some View {
        NavigationStack {
            List {
                Section("Pipeline") {
                    NavigationLink {
                        PipelineStatusView()
                    } label: {
                        Label("Pipeline Status", systemImage: "heart.text.square")
                    }
                }

                Section("Internal") {
                    NavigationLink {
                        InternalSettingsView()
                    } label: {
                        Label("Internal Settings", systemImage: "wrench.and.screwdriver")
                    }
                }

                Section("Redline") {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset Grading Clock", systemImage: "clock.arrow.circlepath")
                    }
                }

                Section("Visibility") {
                    if let url = URL(string: "https://github.com/hcb-gpt/orbit/tree/main/apps/camber-map") {
                        Link(destination: url) {
                            Label("Open Camber Map (Orbit)", systemImage: "map")
                        }
                    } else {
                        Label("Camber Map (link unavailable)", systemImage: "map")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Build") {
                    SettingsKeyValueRow(label: "Version", value: appVersionString)
                    SettingsKeyValueRow(label: "Bundle", value: Bundle.main.bundleIdentifier ?? "unknown")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(bgColor)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(bgColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .confirmationDialog(
                "Reset grading clock?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset to now", role: .destructive) {
                    Task { await contactListViewModel.resetGradingClock() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All current ungraded counts will reset to zero. Only new claims from this moment forward will count as ungraded.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let version, let build { return "\(version) (\(build))" }
        return version ?? build ?? "unknown"
    }
}

private struct InternalSettingsView: View {
    @AppStorage(RedlineInternalSettings.Keys.truthGraphStatusCardEnabled)
    private var truthGraphStatusCardEnabled = false
    @AppStorage(RedlineInternalSettings.Keys.edgeSecret)
    private var edgeSecret = ""
    @State private var isSecretVisible = false

    private let bgColor = Color(white: 0.08)

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            List {
                Section("Truth Graph") {
                    Toggle(isOn: $truthGraphStatusCardEnabled) {
                        Label("Enable status card", systemImage: "stethoscope")
                    }
                }

                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text("X-Edge-Secret")
                            .font(.subheadline)

                        Spacer()

                        Group {
                            if isSecretVisible {
                                TextField("Required for API access", text: $edgeSecret)
                            } else {
                                SecureField("Required for API access", text: $edgeSecret)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Label(edgeSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not set" : "Set", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(isSecretVisible ? "Hide" : "Show") {
                            isSecretVisible.toggle()
                        }
                        .buttonStyle(.borderless)
                    }

                    Button("Clear Edge Secret", role: .destructive) {
                        edgeSecret = ""
                    }
                } header: {
                    Text("Edge Auth")
                } footer: {
                    Text("Used to authenticate internal calls to Supabase Edge Functions. Stored locally on this device.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Internal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(white: 0.06), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
    }
}

private struct SettingsKeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct PipelineStatusView: View {
    @State private var heartbeats: [PipelineHeartbeat] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let bgColor = Color(white: 0.08)

    var body: some View {
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
                        PipelineHeartbeatRow(heartbeat: beat)
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
        .task { await load() }
        .refreshable { await load() }
    }

    private var sortedHeartbeats: [PipelineHeartbeat] {
        heartbeats.sorted { lhs, rhs in
            (lhs.stalenessMinutes ?? .infinity) < (rhs.stalenessMinutes ?? .infinity)
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            heartbeats = try await SupabaseService.shared.fetchPipelineHeartbeat()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct PipelineHeartbeatRow: View {
    let heartbeat: PipelineHeartbeat

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(heartbeat.pipeline)
                    .font(.headline)
                    .foregroundStyle(.white)

                if let date = heartbeat.lastEventAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let stale = heartbeat.stalenessMinutes {
                Text(stalenessLabel(stale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(stale > 60 ? .red : .secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func stalenessLabel(_ minutes: Double) -> String {
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(Int(minutes))m" }
        let hours = Int(minutes / 60)
        return "\(hours)h"
    }
}
