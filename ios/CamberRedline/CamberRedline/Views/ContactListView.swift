import SwiftUI
import os

private enum RedlineSmokeAutomation {
    static let launchFlag = "--smoke-drive"
    static let redlineNotification = Notification.Name("camber.smoke.runRedline")
    static let logger = Logger(subsystem: "CamberRedline", category: "smoke")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }
}

struct ContactListView: View {
    var contactListViewModel: ContactListViewModel
    var threadViewModel: ThreadViewModel

    @State private var searchText = ""
    @State private var showSyncStatus = false
    @State private var showResetConfirmation = false
    @State private var didRunSmokeRedline = false
    @State private var smokeNavigationContact: Contact?

    private var filteredContacts: [Contact] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contactListViewModel.contacts }

        let queryDigits = trimmed.filter(\.isNumber)

        return contactListViewModel.contacts.filter { contact in
            if contact.name.localizedCaseInsensitiveContains(trimmed) {
                return true
            }

            guard !queryDigits.isEmpty else { return false }

            let phoneDigits = (contact.phone ?? "").filter(\.isNumber)
            if !phoneDigits.isEmpty, phoneDigits.contains(queryDigits) {
                return true
            }

            let keyDigits = contact.contactKey.filter(\.isNumber)
            return !keyDigits.isEmpty && keyDigits.contains(queryDigits)
        }
    }

    var body: some View {
        NavigationStack {
            contactListContent
        }
        .preferredColorScheme(.dark)
    }

    private var contactListContent: some View {
        ContactList(contacts: filteredContacts)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search"
            )
            .refreshable {
                await contactListViewModel.loadContacts()
                try? await Task.sleep(for: .milliseconds(300))
            }
            .navigationTitle("Redline")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Contact.self, destination: destinationView(for:))
            .background(Color(white: 0.06))
            .scrollContentBackground(.hidden)
            .toolbarBackground(Color(white: 0.06), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { topBarToolbar }
            .sheet(isPresented: $showSyncStatus, content: syncStatusSheet)
            .confirmationDialog("Reset grading clock?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
                Button("Reset to now", role: .destructive) {
                    Task {
                        await contactListViewModel.resetGradingClock()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All current ungraded counts will reset to zero. Only new claims from this moment forward will count as ungraded.")
            }
            .overlay { loadingOverlay }
            .overlay { searchEmptyOverlay }
            .overlay(alignment: .bottom) { errorOverlay }
            .onReceive(NotificationCenter.default.publisher(for: .redlineAttributionDidResolve)) { _ in
                Task {
                    await contactListViewModel.loadContacts()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: RedlineSmokeAutomation.redlineNotification)) { _ in
                guard RedlineSmokeAutomation.isEnabled else { return }
                guard !didRunSmokeRedline else { return }
                didRunSmokeRedline = true
                Task { await runSmokeRedline() }
            }
    }

    @ToolbarContentBuilder
    private var topBarToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showSyncStatus = true
                } label: {
                    Label("Pipeline Status", systemImage: "heart.text.square")
                }
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset Grading Clock", systemImage: "clock.arrow.circlepath")
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
            }
        }
    }

    private func destinationView(for contact: Contact) -> some View {
        ThreadView(
            viewModel: threadViewModel,
            contact: contact,
            orderedContacts: filteredContacts
        )
    }

    private func syncStatusSheet() -> some View {
        SyncStatusView()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if contactListViewModel.isLoading && contactListViewModel.contacts.isEmpty {
            ProgressView()
                .tint(.white)
        }
    }

    @ViewBuilder
    private var searchEmptyOverlay: some View {
        if !searchText.isEmpty && filteredContacts.isEmpty && !contactListViewModel.isLoading {
            ContentUnavailableView.search(text: searchText)
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var errorOverlay: some View {
        if let error = contactListViewModel.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
        }
    }

    @MainActor
    private func runSmokeRedline() async {
        RedlineSmokeAutomation.logger.log("SMOKE_EVENT REDLINE_START")

        if contactListViewModel.contacts.isEmpty {
            await contactListViewModel.loadContacts()
        }
        try? await Task.sleep(for: .seconds(1))

        guard let first = contactListViewModel.contacts.first else {
            RedlineSmokeAutomation.logger.log("SMOKE_EVENT REDLINE_EMPTY")
            return
        }

        RedlineSmokeAutomation.logger.log("SMOKE_EVENT REDLINE_OPEN_THREAD contact=\(first.contactId, privacy: .public)")
        smokeNavigationContact = first
        try? await Task.sleep(for: .seconds(3))

        RedlineSmokeAutomation.logger.log("SMOKE_EVENT REDLINE_DONE")
    }
}

private struct ContactList: View {
    let contacts: [Contact]

    var body: some View {
        List(contacts) { contact in
            NavigationLink(value: contact) {
                ContactRow(contact: contact)
            }
            .listRowBackground(Color(white: 0.06))
            .listRowSeparatorTint(Color(white: 0.13))
        }
        .listStyle(.plain)
    }
}

// MARK: - Color hex helper

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

private struct SyncStatusView: View {
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
