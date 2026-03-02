import SwiftUI
import UserNotifications
import os

private enum AppSmokeAutomation {
    static let launchFlag = "--smoke-drive"
    static let triageNotification = Notification.Name("camber.smoke.runTriage")
    static let assistantNotification = Notification.Name("camber.smoke.runAssistant")
    static let triageDoneNotification = Notification.Name("camber.smoke.triageDone")
    static let logger = Logger(subsystem: "CamberRedline", category: "smoke")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }
}

private enum ThreadSwipeSmokeAutomation {
    static let launchFlag = "--smoke-thread-swipe"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }
}

private enum TruthGraphDemoAutomation {
    static let launchFlag = "--truth-graph-demo"
    static let interactionIdEnv = "TRUTH_GRAPH_DEMO_INTERACTION_ID"
    static let defaultInteractionId = "cll_missing_2057918239"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }

    static var interactionId: String {
        let raw = (ProcessInfo.processInfo.environment[interactionIdEnv] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? defaultInteractionId : raw
    }
}

private enum RealtimeCleanupProofAutomation {
    static let launchFlag = "--smoke-realtime-cleanup-proof"
    static let logger = Logger(subsystem: "CamberRedline", category: "smoke")

    static var isEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(launchFlag)
#else
        false
#endif
    }
}

enum RedlineTab: Hashable {
    case inbox
    case calls
    case ai
    case dial
    case settings
}

@main
struct CamberRedlineApp: App {
    @State private var contactListViewModel = ContactListViewModel()
    @State private var threadViewModel = ThreadViewModel()
    @State private var selectedTab: RedlineTab = .inbox
    @State private var isTriagePresented = false
    @State private var isTruthGraphDemoPresented = false
    @State private var didRunSmokeDrive = false
    @State private var didRunRealtimeCleanupProof = false
    @Environment(\.scenePhase) private var scenePhase

    // #0A84FF — system blue (Beside-like tint)
    private let besideTint = Color(red: 0.039, green: 0.518, blue: 1.0)
    // #0A0A0A — near-black tab bar background
    private let tabBarBackground = Color(red: 0.039, green: 0.039, blue: 0.039)

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                InboxView(
                    contactListViewModel: contactListViewModel,
                    threadViewModel: threadViewModel,
                    selectedTab: $selectedTab,
                    isTriagePresented: $isTriagePresented
                )
                .tabItem {
                    Label("Inbox", systemImage: "tray.fill")
                }
                .tag(RedlineTab.inbox)

                CallsView()
                    .tabItem {
                        Label("Calls", systemImage: "phone.fill")
                    }
                    .tag(RedlineTab.calls)

                AIView(isTriagePresented: $isTriagePresented)
                    .tabItem {
                        Label("AI", systemImage: "sparkles")
                    }
                    .tag(RedlineTab.ai)

                DialView()
                    .tabItem {
                        Label("Dial", systemImage: "circle.grid.3x3.fill")
                    }
                    .tag(RedlineTab.dial)

                SettingsView(contactListViewModel: contactListViewModel)
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                    .tag(RedlineTab.settings)
            }
            .tint(besideTint)
            .preferredColorScheme(.dark)
            .onAppear {
                let appearance = UITabBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = UIColor(tabBarBackground)
                UITabBar.appearance().standardAppearance = appearance
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }
            .sheet(isPresented: $isTriagePresented) {
                AttributionTriageCardsView()
            }
            .sheet(isPresented: $isTruthGraphDemoPresented) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Truth Graph Demo (Option B)")
                        .font(.headline)
                    Text("Interaction: \(TruthGraphDemoAutomation.interactionId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TruthGraphStatusCardView(
                        viewModel: threadViewModel,
                        unassignedIds: [TruthGraphDemoAutomation.interactionId],
                        probeInteractionId: TruthGraphDemoAutomation.interactionId,
                        reloadThread: {}
                    )

                    Spacer()
                }
                .padding()
                .preferredColorScheme(.dark)
                .presentationDetents([.large])
            }
            .task {
                if TruthGraphDemoAutomation.isEnabled {
                    isTruthGraphDemoPresented = true
                } else if RealtimeCleanupProofAutomation.isEnabled {
                    await runRealtimeCleanupProofIfEnabled()
                } else if AppSmokeAutomation.isEnabled {
                    // Smoke mode: skip Redline bootstrapping to reach triage faster.
                    // Contact list, cache warming, and subscriptions are not needed
                    // for smoke drive and add 3-8s of blocking network time.
                    await runSmokeDriveIfEnabled()
                } else if ThreadSwipeSmokeAutomation.isEnabled {
                    await contactListViewModel.loadContacts()
                    threadViewModel.updateContactSequence(contactListViewModel.contacts)
                    await threadViewModel.warmProjectPickerCache()
                } else {
                    await requestBadgePermission()
                    await contactListViewModel.loadContacts()
                    threadViewModel.updateContactSequence(contactListViewModel.contacts)
                    await threadViewModel.warmProjectPickerCache()
                    updateBadge()
                    await contactListViewModel.subscribeToNewInteractions()
                    contactListViewModel.startLiveRefresh()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task {
                        await contactListViewModel.loadContacts()
                        threadViewModel.updateContactSequence(contactListViewModel.contacts)
                        await threadViewModel.warmProjectPickerCache()
                        updateBadge()
                        await contactListViewModel.subscribeToNewInteractions()
                        if let contact = threadViewModel.currentContact {
                            await threadViewModel.startClaimGradeSubscription(contactId: contact.contactId)
                            await threadViewModel.startInteractionsSubscription(contactId: contact.contactId)
                        }
                    }
                }
            }
            .onChange(of: contactListViewModel.totalUngraded) { _, _ in
                updateBadge()
            }
        }
    }

    private func updateBadge() {
        guard !AppSmokeAutomation.isEnabled else { return }
        guard !ThreadSwipeSmokeAutomation.isEnabled else { return }
        guard !RealtimeCleanupProofAutomation.isEnabled else { return }
        let count = contactListViewModel.totalUngraded
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    private func requestBadgePermission() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.badge])
    }

    @MainActor
    private func runRealtimeCleanupProofIfEnabled() async {
        guard RealtimeCleanupProofAutomation.isEnabled else { return }
        guard !didRunRealtimeCleanupProof else { return }
        didRunRealtimeCleanupProof = true

        RealtimeCleanupProofAutomation.logger.log("SMOKE_EVENT REALTIME_CLEANUP_PROOF_START")

        let contactId = UUID()
        await threadViewModel.startClaimGradeSubscription(contactId: contactId)
        await threadViewModel.startInteractionsSubscription(contactId: contactId)
        await contactListViewModel.subscribeToNewInteractions()

        RealtimeCleanupProofAutomation.logger.log("SMOKE_EVENT REALTIME_CLEANUP_PROOF_END")

        // Brief settle delay so log markers flush before the harness stops streaming.
        try? await Task.sleep(for: .milliseconds(800))
    }

    @MainActor
    private func runSmokeDriveIfEnabled() async {
        guard AppSmokeAutomation.isEnabled else { return }
        guard !didRunSmokeDrive else { return }
        didRunSmokeDrive = true

        AppSmokeAutomation.logger.log("SMOKE_EVENT START")

        // Short settle delay for initial render
        try? await Task.sleep(for: .seconds(1))

        // --- Triage phase ---
        selectedTab = .inbox
        isTriagePresented = true
        AppSmokeAutomation.logger.log("SMOKE_EVENT OPEN_TRIAGE")
        // Give the sheet time to mount and start its queue load
        try? await Task.sleep(for: .milliseconds(900))
        NotificationCenter.default.post(name: AppSmokeAutomation.triageNotification, object: nil)

        // Wait for triage to signal completion (up to 30s timeout)
        await waitForNotification(AppSmokeAutomation.triageDoneNotification, timeout: 30)
        AppSmokeAutomation.logger.log("SMOKE_EVENT TRIAGE_PHASE_COMPLETE")
        isTriagePresented = false
        try? await Task.sleep(for: .milliseconds(600))

        // --- Assistant phase ---
        selectedTab = .ai
        AppSmokeAutomation.logger.log("SMOKE_EVENT OPEN_ASSISTANT")
        try? await Task.sleep(for: .milliseconds(800))
        NotificationCenter.default.post(name: AppSmokeAutomation.assistantNotification, object: nil)

        // Keep assistant visible for prompts + screenshots
        try? await Task.sleep(for: .seconds(18))
        selectedTab = .inbox
        AppSmokeAutomation.logger.log("SMOKE_EVENT END")
    }

    @MainActor
    private func waitForNotification(_ name: Notification.Name, timeout: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in NotificationCenter.default.notifications(named: name) {
                    return
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
            }
            await group.next()
            group.cancelAll()
        }
    }
}
