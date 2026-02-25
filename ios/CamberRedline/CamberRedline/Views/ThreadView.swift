import SwiftUI

struct ThreadView: View {
    var viewModel: ThreadViewModel
    let contact: Contact

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(viewModel.threadItems.enumerated()), id: \.element.id) { index, item in
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
            await viewModel.loadThread(contactId: contact.contactId)
            try? await Task.sleep(for: .milliseconds(500))
        }
        .background(Color.black)
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
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
        .task(id: contact.contactId) {
            viewModel.currentContact = contact
            await viewModel.loadThread(contactId: contact.contactId)
            await viewModel.startClaimGradeSubscription(contactId: contact.contactId)
        }
        .onDisappear {
            Task {
                await viewModel.stopClaimGradeSubscription()
            }
        }
    }

    // MARK: - Date Headers

    private static let dateHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

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
            return Self.dateHeaderFormatter.string(from: date)
        }
    }
}
