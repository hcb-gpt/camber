import SwiftUI
import UserNotifications

@main
struct CamberRedlineApp: App {
    @State private var contactListViewModel = ContactListViewModel()
    @State private var threadViewModel = ThreadViewModel()
    @State private var selectedTab: Int = 0
    @Environment(\.scenePhase) private var scenePhase

    // #FF3B30 — system red (Redline tab tint)
    private let redlineTint = Color(red: 1.0, green: 0.231, blue: 0.188)
    // #30D158 — system green (Triage tab tint)
    private let triageTint = Color(red: 0.188, green: 0.820, blue: 0.345)
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
            }
            .tint(selectedTab == 0 ? redlineTint : triageTint)
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
}
