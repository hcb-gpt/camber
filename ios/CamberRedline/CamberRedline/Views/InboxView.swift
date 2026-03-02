import SwiftUI
import Observation

struct InboxView: View {
    @Bindable var contactListViewModel: ContactListViewModel
    @Bindable var threadViewModel: ThreadViewModel
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
