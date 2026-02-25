import SwiftUI

@main
struct CamberRedlineApp: App {
    @State private var viewModel = ThreadViewModel()

    var body: some Scene {
        WindowGroup {
            ContactListView(viewModel: viewModel)
                .preferredColorScheme(.dark)
                .onAppear {
                    viewModel.loadContacts()
                }
        }
    }
}
