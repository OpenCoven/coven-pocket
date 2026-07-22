import SwiftUI

/// Cloned repositories: clone, open (bind chat), sync, and delete.
struct ReposView: View {
    @StateObject private var model = RepoModel()
    @State private var showClone = false
    @State private var commitTarget: GitWorkspaceSummary?
    @State private var branchTarget: GitWorkspaceSummary?
    @State private var pendingDelete: GitWorkspaceSummary?

    var body: some View {
        NavigationStack {
            Group {
                if model.workspaces.isEmpty {
                    emptyState
                } else {
                    workspaceList
                }
            }
            .navigationTitle("Repos")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showClone = true
                    } label: {
                        Label("Clone", systemImage: "plus")
                    }
                }
                if model.isBusy {
                    ToolbarItem(placement: .topBarLeading) { ProgressView() }
                }
            }
            .task { await model.refresh() }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showClone, onDismiss: refresh) {
                CloneSheet(model: model)
            }
            .sheet(item: $commitTarget, onDismiss: refresh) { workspace in
                CommitSheet(model: model, workspace: workspace)
            }
            .sheet(item: $branchTarget, onDismiss: refresh) { workspace in
                BranchSheet(model: model, workspace: workspace)
            }
            .confirmationDialog(
                "Delete this repo?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { workspace in
                Button("Delete \"\(workspace.name)\"", role: .destructive) {
                    Task { await model.delete(workspace) }
                }
            } message: { _ in
                Text("The local clone and any uncommitted changes are removed.")
            }
            .alert(
                "Git error",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No repos yet",
            systemImage: "arrow.triangle.branch",
            description: Text("Clone a repository to give the agent a real working tree.")
        )
    }

    private var workspaceList: some View {
        List {
            Section {
                ForEach(model.workspaces) { workspace in
                    row(for: workspace)
                }
            } footer: {
                Text("The selected repo is the working directory for new chat sessions.")
            }
        }
    }

    private func row(for workspace: GitWorkspaceSummary) -> some View {
        Button {
            model.setActive(model.activeRepoName == workspace.name ? nil : workspace)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(workspace.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.activeRepoName == workspace.name {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
        .contextMenu { menuItems(for: workspace) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = workspace
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func menuItems(for workspace: GitWorkspaceSummary) -> some View {
        Button {
            Task { await model.pull(workspace) }
        } label: {
            Label("Pull", systemImage: "arrow.down.circle")
        }
        Button {
            Task { await model.push(workspace) }
        } label: {
            Label("Push", systemImage: "arrow.up.circle")
        }
        Button {
            commitTarget = workspace
        } label: {
            Label("Commit…", systemImage: "checkmark.seal")
        }
        Button {
            branchTarget = workspace
        } label: {
            Label("Branches…", systemImage: "arrow.triangle.branch")
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = workspace
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func refresh() {
        Task { await model.refresh() }
    }
}
