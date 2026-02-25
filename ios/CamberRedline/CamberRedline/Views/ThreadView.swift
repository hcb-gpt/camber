import SwiftUI

struct ThreadView: View {
    var viewModel: ThreadViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(viewModel.threadItems.enumerated()), id: \.element.id) { index, item in
                        // Date header when day changes
                        if shouldShowDateHeader(at: index) {
                            dateHeader(for: item)
                        }

                        switch item {
                        case .call(let entry):
                            CallSummaryCard(entry: entry, viewModel: viewModel)
                        case .sms(let entry):
                            SMSBubble(entry: entry)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .defaultScrollAnchor(.bottom)
            .refreshable {
                if let contact = viewModel.currentContact {
                    viewModel.loadThread(contactId: contact.contactId)
                    // Brief delay so the refresh indicator stays visible while loading
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            .background(Color.black)
            .navigationTitle(viewModel.currentContact?.name ?? "Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    contactPicker
                }
            }
            .overlay {
                if viewModel.isLoading && viewModel.threadItems.isEmpty {
                    ProgressView()
                        .tint(.white)
                }
            }
            .overlay(alignment: .bottom) {
                if let error = viewModel.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Contact Picker

    private var contactPicker: some View {
        Menu {
            ForEach(viewModel.contacts) { contact in
                Button {
                    viewModel.currentContact = contact
                    viewModel.loadThread(contactId: contact.contactId)
                } label: {
                    HStack {
                        Text(contact.name)
                        if contact.contactId == viewModel.currentContact?.contactId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "person.crop.circle")
                .imageScale(.large)
        }
    }

    // MARK: - Date Headers

    private func shouldShowDateHeader(at index: Int) -> Bool {
        guard let currentDate = viewModel.threadItems[index].eventAtDate else { return false }
        if index == 0 { return true }
        guard let previousDate = viewModel.threadItems[index - 1].eventAtDate else { return true }
        return !Calendar.current.isDate(currentDate, inSameDayAs: previousDate)
    }

    private func dateHeader(for item: ThreadItem) -> some View {
        Text(dateHeaderText(for: item))
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    private func dateHeaderText(for item: ThreadItem) -> String {
        guard let date = item.eventAtDate else { return "Unknown" }
        if Calendar.current.isDateInToday(date) {
            return "Today"
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}
