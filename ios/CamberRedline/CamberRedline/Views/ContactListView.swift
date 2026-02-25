import SwiftUI

struct ContactListView: View {
    var contactListViewModel: ContactListViewModel
    var threadViewModel: ThreadViewModel

    @State private var searchText = ""

    private var filteredContacts: [Contact] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return contactListViewModel.contacts }
        return contactListViewModel.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredContacts) { contact in
                NavigationLink(value: contact) {
                    ContactRow(contact: contact)
                }
                .listRowBackground(Color(hex: 0x1C1C1E))
                .listRowSeparatorTint(Color(white: 0.15))
            }
            .listStyle(.plain)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search contacts"
            )
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
            .overlay {
                if !searchText.isEmpty && filteredContacts.isEmpty && !contactListViewModel.isLoading {
                    ContentUnavailableView.search(text: searchText)
                        .foregroundStyle(.white)
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
            .onAppear {
                Task {
                    await contactListViewModel.loadContacts()
                    await contactListViewModel.subscribeToNewInteractions()
                    contactListViewModel.startLiveRefresh()
                }
            }
            .onDisappear {
                contactListViewModel.stopLiveRefresh()
                Task {
                    await contactListViewModel.unsubscribe()
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Color hex helper

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
