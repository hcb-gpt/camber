import SwiftUI
import UserNotifications
import os

private enum AppSmokeAutomation {
    static let launchFlag = "--smoke-drive"
    static let triageNotification = Notification.Name("camber.smoke.runTriage")
    static let assistantNotification = Notification.Name("camber.smoke.runAssistant")
    static let logger = Logger(subsystem: "CamberRedline", category: "smoke")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }
}

@main
struct CamberRedlineApp: App {
    @State private var contactListViewModel = ContactListViewModel()
    @State private var threadViewModel = ThreadViewModel()
    @State private var selectedTab: Int = 0
    @State private var didRunSmokeDrive = false
    @Environment(\.scenePhase) private var scenePhase

    // #FF3B30 — system red (Redline tab tint)
    private let redlineTint = Color(red: 1.0, green: 0.231, blue: 0.188)
    // #30D158 — system green (Triage tab tint)
    private let triageTint = Color(red: 0.188, green: 0.820, blue: 0.345)
    // #5E5CE6 — system indigo (Context tab tint)
    private let contextTint = Color(red: 0.369, green: 0.361, blue: 0.902)
    // #0A0A0A — near-black tab bar background
    private let tabBarBackground = Color(red: 0.039, green: 0.039, blue: 0.039)

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                ContactListView(
                    contactListViewModel: contactListViewModel,
                    threadViewModel: threadViewModel
                )
                .tabItem {
                    Label("Redline", systemImage: "phone.fill")
                }
                .tag(0)

                AttributionTriageCardsView()
                .tabItem {
                    Label("Triage", systemImage: "checkmark.circle.fill")
                }
                .tag(1)

                NavigationStack {
                    AssistantChatView()
                }
                .tabItem {
                    Label("Assistant", systemImage: "brain.head.profile")
                }
                .tag(2)
            }
            .tint(selectedTab == 0 ? redlineTint : selectedTab == 1 ? triageTint : contextTint)
            .preferredColorScheme(.dark)
            .onAppear {
                let appearance = UITabBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = UIColor(tabBarBackground)
                UITabBar.appearance().standardAppearance = appearance
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }
            .task {
                await requestBadgePermission()
                await contactListViewModel.loadContacts()
                threadViewModel.updateContactSequence(contactListViewModel.contacts)
                await threadViewModel.warmProjectPickerCache()
                updateBadge()
                await contactListViewModel.subscribeToNewInteractions()
                contactListViewModel.startLiveRefresh()
                await runSmokeDriveIfEnabled()
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

        try? await Task.sleep(for: .seconds(2))
        selectedTab = 1
        AppSmokeAutomation.logger.log("SMOKE_EVENT OPEN_TRIAGE")
        try? await Task.sleep(for: .milliseconds(1200))
        NotificationCenter.default.post(name: AppSmokeAutomation.triageNotification, object: nil)

        try? await Task.sleep(for: .seconds(8))
        selectedTab = 2
        AppSmokeAutomation.logger.log("SMOKE_EVENT OPEN_ASSISTANT")
        try? await Task.sleep(for: .milliseconds(1200))
        NotificationCenter.default.post(name: AppSmokeAutomation.assistantNotification, object: nil)

        // Keep the assistant tab visible long enough for:
        // - assistant-context fetch
        // - 3 smoke prompts
        // - screenshots from the simulator harness
        try? await Task.sleep(for: .seconds(18))
        selectedTab = 0
        AppSmokeAutomation.logger.log("SMOKE_EVENT END")
    }
}
