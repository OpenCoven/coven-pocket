import SwiftUI

/// Clone form: URL, optional folder name, and remote credentials. Secrets
/// are written to the Keychain and reused for pull/push on every repo.
struct CloneSheet: View {
    @ObservedObject var model: RepoModel
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var name = ""
    @State private var username = Keychain.get(RepoModel.usernameKey) ?? ""
    @State private var token = Keychain.get(RepoModel.tokenKey) ?? ""
    @State private var sshKey = Keychain.get(RepoModel.sshKeyKey) ?? ""
    @State private var sshPassphrase = Keychain.get(RepoModel.sshPassphraseKey) ?? ""
    @State private var isCloning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Repository") {
                    TextField("https://… or git@…", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Folder name (optional)", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Token or password", text: $token)
                } header: {
                    Text("HTTPS")
                } footer: {
                    Text("For private HTTPS remotes, use a personal access token.")
                }
                Section {
                    SecureField("Private key passphrase", text: $sshPassphrase)
                    TextEditor(text: $sshKey)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(minHeight: 80)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("SSH private key")
                } footer: {
                    Text("Paste a PEM key for git@ remotes. Stored in the Keychain.")
                }
            }
            .navigationTitle("Clone repo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCloning {
                        ProgressView()
                    } else {
                        Button("Clone") { clone() }
                            .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(isCloning)
        }
    }

    private func clone() {
        saveCredentials()
        isCloning = true
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        Task {
            await model.clone(url: trimmedURL, name: trimmedName.isEmpty ? nil : trimmedName)
            isCloning = false
            dismiss()
        }
    }

    private func saveCredentials() {
        store(username, key: RepoModel.usernameKey)
        store(token, key: RepoModel.tokenKey)
        store(sshKey, key: RepoModel.sshKeyKey)
        store(sshPassphrase, key: RepoModel.sshPassphraseKey)
    }

    private func store(_ value: String, key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(key)
        } else {
            Keychain.set(trimmed, for: key)
        }
    }
}

/// Stage-all commit with a message and a persisted author identity.
struct CommitSheet: View {
    @ObservedObject var model: RepoModel
    let workspace: GitWorkspaceSummary
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var authorName = ""
    @State private var authorEmail = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Message") {
                    TextField("Commit message", text: $message, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section("Author") {
                    TextField("Name", text: $authorName)
                    TextField("Email", text: $authorEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Commit all")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let author = model.author()
                authorName = author.name
                authorEmail = author.email
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Commit") {
                        model.setAuthor(name: authorName, email: authorEmail)
                        let text = message
                        Task {
                            await model.commitAll(workspace, message: text)
                            dismiss()
                        }
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Switch or create branches. Existing origin branches check out with
/// tracking; dirty worktrees are refused by the engine with a clear error.
struct BranchSheet: View {
    @ObservedObject var model: RepoModel
    let workspace: GitWorkspaceSummary
    @Environment(\.dismiss) private var dismiss

    @State private var branches: [String] = []
    @State private var newBranch = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Switch to") {
                    ForEach(branches, id: \.self) { branch in
                        Button {
                            Task {
                                await model.checkout(workspace, branch: branch, create: false)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(branch)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if branch == workspace.branch {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
                Section("New branch") {
                    HStack {
                        TextField("feature/name", text: $newBranch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Create") {
                            let branch = newBranch.trimmingCharacters(in: .whitespaces)
                            Task {
                                await model.checkout(workspace, branch: branch, create: true)
                                dismiss()
                            }
                        }
                        .disabled(newBranch.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle(workspace.name)
            .navigationBarTitleDisplayMode(.inline)
            .task { branches = await model.branches(workspace) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
