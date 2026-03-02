import SwiftUI

struct SettingsView: View {
    var contactListViewModel: ContactListViewModel

    @State private var showResetConfirmation = false
#if DEBUG
    @AppStorage(InternalModeConfig.enabledDefaultsKey) private var isInternalModeEnabled = false
    @State private var edgeSecretDraft = ""
    @State private var hasStoredEdgeSecret = false
    @State private var internalModeMessage: String?
#endif

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

#if DEBUG
                Section("Internal Mode (DEBUG)") {
                    Toggle("Internal Mode", isOn: $isInternalModeEnabled)

                    SecureField("X-Edge-Secret (stored in Keychain)", text: $edgeSecretDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack(spacing: 12) {
                        Button("Save Secret") {
                            saveEdgeSecret()
                        }
                        .disabled(edgeSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Wipe Stored Secret", role: .destructive) {
                            wipeEdgeSecret()
                        }
                        .disabled(!hasStoredEdgeSecret)
                    }

                    if hasStoredEdgeSecret {
                        Label("Edge secret stored (not shown)", systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("No edge secret stored", systemImage: "xmark.seal")
                            .foregroundStyle(.secondary)
                    }

                    if let internalModeMessage {
                        Text(internalModeMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("When enabled, `X-Edge-Secret` is attached only to bootstrap-review write actions (resolve/dismiss/undo). It is never sent on queue GET requests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
#endif
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
#if DEBUG
        .task { refreshEdgeSecretState() }
#endif
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let version, let build { return "\(version) (\(build))" }
        return version ?? build ?? "unknown"
    }

#if DEBUG
    @MainActor
    private func refreshEdgeSecretState() {
        do {
            let stored = try KeychainStore.read(
                service: InternalModeConfig.edgeSecretKeychainService,
                account: InternalModeConfig.edgeSecretKeychainAccount
            )
            hasStoredEdgeSecret = stored != nil
        } catch {
            hasStoredEdgeSecret = false
            internalModeMessage = "Unable to read Keychain item (\(error.localizedDescription))."
        }
    }

    @MainActor
    private func saveEdgeSecret() {
        let trimmed = edgeSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            internalModeMessage = "Secret is empty."
            return
        }

        do {
            try KeychainStore.upsert(
                service: InternalModeConfig.edgeSecretKeychainService,
                account: InternalModeConfig.edgeSecretKeychainAccount,
                value: Data(trimmed.utf8)
            )
            edgeSecretDraft = ""
            internalModeMessage = "Saved."
            refreshEdgeSecretState()
        } catch {
            internalModeMessage = "Unable to save to Keychain (\(error.localizedDescription))."
        }
    }

    @MainActor
    private func wipeEdgeSecret() {
        do {
            try KeychainStore.delete(
                service: InternalModeConfig.edgeSecretKeychainService,
                account: InternalModeConfig.edgeSecretKeychainAccount
            )
            internalModeMessage = "Wiped."
            refreshEdgeSecretState()
        } catch {
            internalModeMessage = "Unable to wipe Keychain item (\(error.localizedDescription))."
        }
    }
#endif
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
