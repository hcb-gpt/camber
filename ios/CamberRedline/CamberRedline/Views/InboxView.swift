import SwiftUI

struct InboxView: View {
    var contactListViewModel: ContactListViewModel
    var threadViewModel: ThreadViewModel
    @Binding var selectedTab: RedlineTab
    @Binding var isTriagePresented: Bool

    var body: some View {
        ContactListView(
            contactListViewModel: contactListViewModel,
            threadViewModel: threadViewModel,
            selectedTab: $selectedTab,
            isTriagePresented: $isTriagePresented
        )
    }
}

