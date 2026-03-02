import SwiftUI

struct ContactInfoView: View {
    let contact: Contact

    @Environment(\.dismiss) private var dismiss

    private let bgColor = Color(white: 0.06)

    var body: some View {
        NavigationStack {
            List {
                Section("Contact") {
                    infoRow(label: "Name", value: contact.name)
                    infoRow(label: "Phone", value: contact.phone ?? "—")
                }

                Section("Counts") {
                    infoRow(label: "Calls", value: "\(contact.callCount)")
                    infoRow(label: "Messages", value: "\(contact.smsCount)")
                    infoRow(label: "Claims", value: "\(contact.claimCount)")
                    infoRow(label: "Pending", value: "\(contact.ungradedCount)")
                }

                Section("IDs") {
                    infoRow(label: "Contact ID", value: contact.contactId.uuidString)
                    infoRow(label: "Contact Key", value: contact.contactKey)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(bgColor)
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(bgColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

