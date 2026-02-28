import SwiftUI

struct ProjectPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let card: CardItem
    let projects: [ReviewProject]
    let onSelect: (String) -> Void
    let onDismissItem: () -> Void

    @State private var searchText = ""

    private var filtered: [ReviewProject] {
        guard !searchText.isEmpty else { return projects }
        let query = searchText.lowercased()
        return projects.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filtered) { project in
                        Button {
                            dismiss()
                            onSelect(project.id)
                        } label: {
                            HStack(spacing: 10) {
                                Text(project.name)
                                    .foregroundStyle(.white)
                                Spacer()
                                if project.id == card.projectId {
                                    Image(systemName: "cpu")
                                        .font(.caption)
                                        .foregroundStyle(Color(red: 0.188, green: 0.82, blue: 0.345))
                                }
                            }
                        }
                    }
                } header: {
                    Text("Pick a project")
                }

                Section {
                    Button(role: .destructive) {
                        dismiss()
                        onDismissItem()
                    } label: {
                        Label("Dismiss this item", systemImage: "xmark.circle")
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search projects")
            .navigationTitle(card.contactName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
