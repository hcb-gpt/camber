import SwiftUI

struct ContactListView: View {
    var contactListViewModel: ContactListViewModel
    var threadViewModel: ThreadViewModel

    var body: some View {
        NavigationStack {
            List(contactListViewModel.contacts) { contact in
                NavigationLink(value: contact) {
                    ContactRow(contact: contact)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color(white: 0.2))
            }
            .listStyle(.plain)
            .refreshable {
                await contactListViewModel.loadContacts()
                try? await Task.sleep(for: .milliseconds(300))
            }
            .navigationTitle("Redline")
            .navigationDestination(for: Contact.self) { contact in
                ThreadView(viewModel: threadViewModel, contact: contact)
            }
            .background(Color.black)
            .scrollContentBackground(.hidden)
            .overlay {
                if contactListViewModel.isLoading && contactListViewModel.contacts.isEmpty {
                    ProgressView()
                        .tint(.white)
                }
            }
            .overlay(alignment: .bottom) {
                if let error = contactListViewModel.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
            .task {
                if contactListViewModel.contacts.isEmpty {
                    await contactListViewModel.loadContacts()
                }
                await contactListViewModel.subscribeToNewInteractions()
            }
        }
        .preferredColorScheme(.dark)
    }
}
