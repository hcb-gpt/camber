import SwiftUI

@main
struct CamberRedlineApp: App {
    @State private var contactListViewModel = ContactListViewModel()
    @State private var threadViewModel = ThreadViewModel()

    var body: some Scene {
        WindowGroup {
            ContactListView(
                contactListViewModel: contactListViewModel,
                threadViewModel: threadViewModel
            )
                .preferredColorScheme(.dark)
        }
    }
}
