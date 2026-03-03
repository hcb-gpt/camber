import SwiftUI

struct SettingsView: View {
    var contactListViewModel: ContactListViewModel

    @State private var showResetConfirmation = false
    #if DEBUG
    @State private var internalModeEnabled = BootstrapService.shared.isInternalModeEnabled()
    @State private var writeStubEnabled = BootstrapService.shared.isWriteStubEnabled()
    @State private var edgeSecretDraft = ""
    @State private var hasStoredEdgeSecret = BootstrapService.shared.hasStoredEdgeSecret()
    @State private var internalModeStatusMessage: String?
    @AppStorage("triage_surface_mode_v1") private var triageSurfaceModeRawValue = TriageSurfaceMode.contractor.rawValue
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

                #if DEBUG
                Section("Internal Mode (DEBUG)") {
                    Toggle("Enable privileged attribution writes", isOn: $internalModeEnabled)
                        .onChange(of: internalModeEnabled) { _, newValue in
                            BootstrapService.shared.setInternalModeEnabled(newValue)
                            if !newValue {
                                writeStubEnabled = false
                                BootstrapService.shared.setWriteStubEnabled(false)
                            }
                        }

                    Toggle("Allow local write stub when auth lock is active", isOn: $writeStubEnabled)
                        .onChange(of: writeStubEnabled) { _, newValue in
                            BootstrapService.shared.setWriteStubEnabled(newValue)
                        }
                        .disabled(!internalModeEnabled)

                    VStack(alignment: .leading, spacing: 6) {
                        SecureField("X-Edge-Secret (stored in Keychain)", text: $edgeSecretDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())

                        HStack {
                            Button("Save Secret") {
                                let secret = edgeSecretDraft
                                edgeSecretDraft = ""
                                internalModeStatusMessage = nil
                                do {
                                    try BootstrapService.shared.storeEdgeSecret(secret)
                                    hasStoredEdgeSecret = BootstrapService.shared.hasStoredEdgeSecret()
                                    internalModeStatusMessage = "Saved to Keychain (write lock cleared)."
                                } catch {
                                    internalModeStatusMessage = error.localizedDescription
                                }
                            }
                            .disabled(edgeSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Spacer()

                            Button("Clear Write Lock") {
                                BootstrapService.shared.clearWriteLock()
                                internalModeStatusMessage = "Write lock cleared."
                            }
                            .disabled(BootstrapService.shared.writeLockState == nil)
                        }

                        Button("Wipe Secret", role: .destructive) {
                            internalModeStatusMessage = nil
                            do {
                                try BootstrapService.shared.wipeStoredEdgeSecret()
                                hasStoredEdgeSecret = false
                                internalModeStatusMessage = "Secret wiped."
                            } catch {
                                internalModeStatusMessage = error.localizedDescription
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(hasStoredEdgeSecret ? "Secret stored in Keychain." : "No secret stored.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Group {
                            if let banner = BootstrapService.shared.writesLockedBannerText {
                                Text(banner)
                            } else if internalModeEnabled && writeStubEnabled {
                                Text("Local write stub armed. It activates only when auth lock is observed.")
                            } else if !internalModeEnabled {
                                Text("Privileged attribution writes disabled (Internal Mode off).")
                            } else if !hasStoredEdgeSecret {
                                Text("Privileged attribution writes enabled, but no X-Edge-Secret is stored; write actions will be rejected (403 invalid_auth).")
                            } else {
                                Text("Privileged attribution writes enabled.")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle((internalModeEnabled && !hasStoredEdgeSecret) ? .orange : .secondary)

                        if let internalModeStatusMessage {
                            Text(internalModeStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                #endif

                #if DEBUG
                Section("Triage Surface (DEBUG)") {
                    Picker("Mode", selection: $triageSurfaceModeRawValue) {
                        Text("Contractor").tag(TriageSurfaceMode.contractor.rawValue)
                        Text("Dev").tag(TriageSurfaceMode.dev.rawValue)
                    }
                    .pickerStyle(.segmented)

                    Text("Contractor hides model/confidence/evidence metadata. Dev exposes diagnostics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif

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
