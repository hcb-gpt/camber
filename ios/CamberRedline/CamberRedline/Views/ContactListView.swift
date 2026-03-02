import SwiftUI

fileprivate enum InboxFilter: String, CaseIterable {
    case all = "All"
    case unread = "Unread"
}

struct ContactListView: View {
    var contactListViewModel: ContactListViewModel
    var threadViewModel: ThreadViewModel
    @Binding var selectedTab: RedlineTab
    @Binding var isTriagePresented: Bool

    @State private var searchText = ""
    @State private var filter: InboxFilter = .all

    private var filteredContactsBySearch: [Contact] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contactListViewModel.contacts }

        let queryDigits = trimmed.filter(\.isNumber)

        return contactListViewModel.contacts.filter { contact in
            if contact.name.localizedCaseInsensitiveContains(trimmed) {
                return true
            }

            guard !queryDigits.isEmpty else { return false }

            let phoneDigits = (contact.phone ?? "").filter(\.isNumber)
            if !phoneDigits.isEmpty, phoneDigits.contains(queryDigits) {
                return true
            }

            let keyDigits = contact.contactKey.filter(\.isNumber)
            return !keyDigits.isEmpty && keyDigits.contains(queryDigits)
        }
    }

    private var visibleContacts: [Contact] {
        let contacts = filteredContactsBySearch
        switch filter {
        case .all:
            return contacts
        case .unread:
            // Placeholder mapping (until backend provides a true unread metric):
            // "Unread" == "has ungraded triage pressure"
            return contacts.filter { $0.ungradedCount > 0 }
        }
    }

    var body: some View {
        NavigationStack {
            contactListContent
        }
        .preferredColorScheme(.dark)
    }

    private var contactListContent: some View {
        ContactList(
            contacts: visibleContacts,
            selectedTab: $selectedTab,
            filter: $filter
        )
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search or Ask Redline AI"
            )
            .refreshable {
                await contactListViewModel.loadContacts()
                try? await Task.sleep(for: .milliseconds(300))
            }
            .navigationTitle("Redline")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Contact.self, destination: destinationView(for:))
            .background(Color(white: 0.06))
            .scrollContentBackground(.hidden)
            .toolbarBackground(Color(white: 0.06), for: ToolbarPlacement.navigationBar)
            .toolbarBackground(.visible, for: ToolbarPlacement.navigationBar)
            .toolbar { topBarToolbar }
            .overlay { loadingOverlay }
            .overlay { searchEmptyOverlay }
            .overlay(alignment: Alignment.bottom) { errorOverlay }
            .onReceive(NotificationCenter.default.publisher(for: .redlineAttributionDidResolve)) { _ in
                Task {
                    await contactListViewModel.loadContacts()
                }
            }
    }

    @ToolbarContentBuilder
    private var topBarToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isTriagePresented = true
            } label: {
                Label("Triage", systemImage: "checkmark.circle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color(white: 0.55))
            }
            .accessibilityLabel("Open triage")
        }
    }

    private func destinationView(for contact: Contact) -> some View {
        ThreadView(
            viewModel: threadViewModel,
            contact: contact,
            orderedContacts: visibleContacts
        )
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if contactListViewModel.isLoading && contactListViewModel.contacts.isEmpty {
            ProgressView()
                .tint(.white)
        }
    }

    @ViewBuilder
    private var searchEmptyOverlay: some View {
        if !searchText.isEmpty && visibleContacts.isEmpty && !contactListViewModel.isLoading {
            ContentUnavailableView.search(text: searchText)
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var errorOverlay: some View {
        if let error = contactListViewModel.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
        }
    }
}

private struct ContactList: View {
    let contacts: [Contact]
    @Binding var selectedTab: RedlineTab
    @Binding var filter: InboxFilter

    var body: some View {
        List {
            Section {
                filterRow
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color(white: 0.06))
                    .listRowSeparator(.hidden)
            }

            Section {
                askAIRow
                ForEach(contacts) { contact in
                    NavigationLink(value: contact) {
                        ContactRow(contact: contact)
                    }
                    .listRowBackground(Color(white: 0.06))
                    .listRowSeparatorTint(Color(white: 0.13))
                }
            }
        }
        .listStyle(.plain)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                pill(InboxFilter.all.rawValue, isSelected: filter == .all) {
                    filter = .all
                }
                pill(InboxFilter.unread.rawValue, isSelected: filter == .unread) {
                    filter = .unread
                }
                pill("Ask AI", isSelected: false, icon: "sparkles") {
                    selectedTab = .ai
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var askAIRow: some View {
        Button {
            selectedTab = .ai
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.26, green: 0.62, blue: 1.0),
                                Color(red: 0.60, green: 0.32, blue: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask Redline AI")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Ask about calls & context")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(white: 0.45))
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color(white: 0.06))
        .listRowSeparatorTint(Color(white: 0.13))
        .accessibilityLabel("Ask Redline AI")
    }

    private func pill(_ title: String, isSelected: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? .black : .white)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.white : Color(white: 0.14))
            )
        }
        .buttonStyle(.plain)
    }
}

 
