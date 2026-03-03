import SwiftUI

struct ProjectPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let card: CardItem
    let projects: [ReviewProject]
    var recentProjects: [ReviewProject] = []
    var suggestedProject: ReviewProject? = nil
    let onSelect: (String) -> Void
    let onDismissItem: () -> Void
    let onBizDevNoProject: () -> Void
    var showsDismissAction: Bool = true
    var writesLocked: Bool = false
    var writesLockedBannerText: String? = nil

    @State private var searchText = ""

    private var filtered: [ReviewProject] {
        guard !searchText.isEmpty else { return projects }
        let query = searchText.lowercased()
        return projects.filter { $0.name.lowercased().contains(query) }
    }

    private var hasQuickPicks: Bool {
        suggestedProject != nil || !recentProjects.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if writesLocked, let writesLockedBannerText {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)
                            Text(writesLockedBannerText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if hasQuickPicks {
                    Section("Quick pick") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                if let suggestedProject {
                                    quickPickButton(
                                        project: suggestedProject,
                                        title: "Suggested",
                                        icon: "cpu"
                                    )
                                }

                                ForEach(recentProjects.prefix(6)) { recentProject in
                                    quickPickButton(
                                        project: recentProject,
                                        title: "Recent",
                                        icon: "clock.arrow.circlepath"
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

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
                        .disabled(writesLocked)
                    }
                } header: {
                    Text("Pick a project")
                }

                if showsDismissAction {
                    Section {
                        Button {
                            dismiss()
                            onBizDevNoProject()
                        } label: {
                            Label("BizDev / No Project", systemImage: "briefcase")
                        }
                        .disabled(writesLocked)

                        Button(role: .destructive) {
                            dismiss()
                            onDismissItem()
                        } label: {
                            Label("Dismiss this item", systemImage: "xmark.circle")
                        }
                        .disabled(writesLocked)
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

    private func quickPickButton(project: ReviewProject, title: String, icon: String) -> some View {
        Button {
            dismiss()
            onSelect(project.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(project.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(red: 0.145, green: 0.145, blue: 0.157), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(red: 0.165, green: 0.165, blue: 0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(writesLocked)
    }
}
