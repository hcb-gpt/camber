import SwiftUI

struct ContactListView: View {
    var viewModel: ThreadViewModel
    @State private var searchText = ""

    private var filteredContacts: [Contact] {
        if searchText.isEmpty { return viewModel.contacts }
        return viewModel.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.phone.contains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredContacts) { contact in
                NavigationLink(value: contact) {
                    ContactRow(contact: contact)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color(white: 0.2))
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search or Ask Redline")
            .navigationTitle("Redline")
            .navigationDestination(for: Contact.self) { contact in
                ThreadView(viewModel: viewModel, contact: contact)
            }
            .background(Color.black)
            .scrollContentBackground(.hidden)
            .overlay {
                if viewModel.isLoading && viewModel.contacts.isEmpty {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
