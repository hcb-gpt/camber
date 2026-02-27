import SwiftUI

struct ContactListView: View {
    var contactListViewModel: ContactListViewModel
    var threadViewModel: ThreadViewModel

    @State private var searchText = ""
    @State private var showResetConfirmation = false

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
                .listRowBackground(Color(white: 0.06))
                .listRowSeparatorTint(Color(white: 0.13))
            }
            .listStyle(.plain)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search"
            )
            .refreshable {
                await contactListViewModel.loadContacts()
                try? await Task.sleep(for: .milliseconds(300))
            }
            .navigationTitle("Redline")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Contact.self) { contact in
                ThreadView(viewModel: threadViewModel, contact: contact)
            }
            .background(Color(white: 0.06))
            .scrollContentBackground(.hidden)
            .toolbarBackground(Color(white: 0.06), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
            }
            .confirmationDialog("Reset grading clock?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
                Button("Reset to now", role: .destructive) {
                    Task {
                        await contactListViewModel.resetGradingClock()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All current ungraded counts will reset to zero. Only new claims from this moment forward will count as ungraded.")
            }
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
            .onReceive(NotificationCenter.default.publisher(for: .redlineAttributionDidResolve)) { _ in
                Task {
                    await contactListViewModel.loadContacts()
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
