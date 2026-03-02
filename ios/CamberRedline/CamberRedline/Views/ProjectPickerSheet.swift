import SwiftUI
import Foundation

struct ProjectPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("camber_redline_project_picker_recents_v1") private var recentsJson: String = ""

    let card: CardItem
    let projects: [ReviewProject]
    let onSelect: (String) -> Void
    let onDismissItem: () -> Void
    let onBizDevNoProject: () -> Void
    var showsDismissAction: Bool = true
    var writesLocked: Bool = false
    var writesLockedBannerText: String? = nil

    @State private var searchText = ""

    private var projectsById: [String: ReviewProject] {
        Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    }

    private var filtered: [ReviewProject] {
        guard !searchText.isEmpty else { return projects }
        let query = searchText.lowercased()
        return projects.filter { $0.name.lowercased().contains(query) }
    }

    private var recentProjectIds: [String] {
        guard let data = recentsJson.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    private var recentProjects: [ReviewProject] {
        recentProjectIds.compactMap { projectsById[$0] }
    }

    private var suggestedProject: ReviewProject? {
        guard let suggestedId = card.projectId else { return nil }
        return projectsById[suggestedId]
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

                if searchText.isEmpty, let suggestedProject {
                    Section {
                        Button {
                            recordRecentProjectId(suggestedProject.id)
                            dismiss()
                            onSelect(suggestedProject.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "cpu")
                                    .font(.caption)
                                    .foregroundStyle(Color(red: 0.188, green: 0.82, blue: 0.345))
                                Text(suggestedProject.name)
                                    .foregroundStyle(.white)
                                Spacer()
                                Text("Suggested")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(writesLocked)
                    } header: {
                        Text("Suggested")
                    }
                }

                if searchText.isEmpty, !recentProjects.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recentProjects) { project in
                                    Button {
                                        recordRecentProjectId(project.id)
                                        dismiss()
                                        onSelect(project.id)
                                    } label: {
                                        Text(project.name)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(Color(red: 0.145, green: 0.145, blue: 0.157), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(writesLocked)
                                    .opacity(writesLocked ? 0.6 : 1)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    } header: {
                        Text("Recents")
                    }
                }

                Section {
                    ForEach(filtered) { project in
                        Button {
                            recordRecentProjectId(project.id)
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

    private func recordRecentProjectId(_ projectId: String) {
        var ids = recentProjectIds.filter { $0 != projectId }
        ids.insert(projectId, at: 0)
        ids = Array(ids.prefix(6))

        guard let data = try? JSONEncoder().encode(ids),
              let json = String(data: data, encoding: .utf8)
        else { return }
        recentsJson = json
    }
}
