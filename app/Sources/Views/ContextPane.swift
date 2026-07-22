import SwiftUI

/// iPad detail column: what the agent currently sees — active workspace
/// status, the context that would inject, and the workspace's memory notes.
struct ContextPane: View {
    @StateObject private var model = ContextPaneModel()

    var body: some View {
        List {
            workspaceSection
            contextSection
            notesSection
        }
        .navigationTitle("Context")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }

    private var workspaceSection: some View {
        Section("Workspace") {
            if let workspace = model.activeWorkspace {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name).font(.body.weight(.medium))
                    Text(Self.statusLine(for: workspace))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Scratch workspace")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var contextSection: some View {
        Section("Injected context") {
            if let context = model.context, !context.sources.isEmpty {
                ForEach(context.sources, id: \.self) { source in
                    Label(source, systemImage: "doc.text")
                        .font(.footnote)
                }
                if context.truncated {
                    Label("Truncated at the size budget.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Nothing to inject.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notesSection: some View {
        Section("Memory notes") {
            if model.notes.isEmpty {
                Text("No memory notes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.notes, id: \.filename) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.displayName).font(.footnote)
                    if !note.description.isEmpty {
                        Text(note.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    /// "main · 3 changed · ↑1 ↓2" — omitting whatever is zero.
    static func statusLine(for workspace: GitWorkspaceSummary) -> String {
        var parts = [workspace.branch]
        if workspace.dirtyCount > 0 {
            parts.append("\(workspace.dirtyCount) changed")
        }
        var arrows: [String] = []
        if workspace.ahead > 0 { arrows.append("↑\(workspace.ahead)") }
        if workspace.behind > 0 { arrows.append("↓\(workspace.behind)") }
        if !arrows.isEmpty {
            parts.append(arrows.joined(separator: " "))
        }
        return parts.joined(separator: " · ")
    }
}

/// Read-only context state; every value is re-derived on refresh.
@MainActor
final class ContextPaneModel: ObservableObject {
    @Published var activeWorkspace: GitWorkspaceSummary?
    @Published var context: ProjectContext?
    @Published var notes: [MemoryNote] = []

    private let engine = PocketEngine()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func refresh() async {
        let workspacePath = defaults.string(forKey: ChatModel.activeWorkspacePathKey)
        if let name = defaults.string(forKey: RepoModel.activeRepoNameKey) {
            let workspaces = (try? await engine.gitListWorkspaces(
                workspacesDir: RepoModel.reposURL.path
            )) ?? []
            activeWorkspace = workspaces.first { $0.name == name }
        } else {
            activeWorkspace = nil
        }
        let effectivePath = workspacePath ?? ChatModel.workspaceURL.path
        context = try? await engine.projectContext(workspaceDir: effectivePath)
        notes = (try? await engine.listMemoryNotes(workspaceDir: effectivePath)) ?? []
    }
}
