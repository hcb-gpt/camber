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
    @State private var didRunSmokeDrive = false
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
            .task {
                if AppSmokeAutomation.isEnabled {
                    // Smoke mode: skip Redline bootstrapping to reach triage faster.
                    // Contact list, cache warming, and subscriptions are not needed
                    // for smoke drive and add 3-8s of blocking network time.
                    await runSmokeDriveIfEnabled()
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
        let count = contactListViewModel.totalUngraded
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    private func requestBadgePermission() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.badge])
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
