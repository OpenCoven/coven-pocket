import Foundation

/// Drives the Repos tab: cloned git workspaces the agent can operate in.
/// All engine calls are async FFI (libgit2 work runs on Rust worker
/// threads); this model just owns UI state and credential lookup.
@MainActor
final class RepoModel: ObservableObject {
    @Published var workspaces: [GitWorkspaceSummary] = []
    @Published var isBusy = false
    @Published var errorMessage: String?
    /// Name of the workspace chat sessions bind to, or nil for the scratch
    /// workspace. Persisted alongside the absolute path read by ChatModel.
    @Published private(set) var activeRepoName: String?

    let engine = PocketEngine()

    private let defaults: UserDefaults

    static let activeRepoNameKey = "active-repo-name"

    // Keychain slots for remote credentials, shared across repositories.
    static let usernameKey = "git-username"
    static let tokenKey = "git-token"
    static let sshKeyKey = "git-ssh-key"
    static let sshPassphraseKey = "git-ssh-passphrase"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activeRepoName = defaults.string(forKey: Self.activeRepoNameKey)
    }

    /// Where cloned repositories live. Under Documents so users can inspect
    /// working trees in the Files app.
    static var reposURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("repos", isDirectory: true)
    }

    /// Stored remote credentials. Assembled per call; secrets stay in the
    /// Keychain otherwise.
    static func storedCredentials() -> GitCredentials {
        GitCredentials(
            username: Keychain.get(usernameKey),
            token: Keychain.get(tokenKey),
            sshPrivateKey: Keychain.get(sshKeyKey),
            sshPassphrase: Keychain.get(sshPassphraseKey)
        )
    }

    func refresh() async {
        do {
            workspaces = try await engine.gitListWorkspaces(workspacesDir: Self.reposURL.path)
            // Drop a stale selection when its workspace disappeared.
            if let name = activeRepoName, !workspaces.contains(where: { $0.name == name }) {
                setActive(nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Bind chat sessions to `workspace`, or back to the scratch dir on nil.
    func setActive(_ workspace: GitWorkspaceSummary?) {
        activeRepoName = workspace?.name
        defaults.set(workspace?.name, forKey: Self.activeRepoNameKey)
        defaults.set(workspace?.path, forKey: ChatModel.activeWorkspacePathKey)
    }

    func clone(url: String, name: String?) async {
        await run {
            _ = try await self.engine.gitClone(
                workspacesDir: Self.reposURL.path,
                url: url,
                name: name,
                credentials: Self.storedCredentials()
            )
        }
    }

    func delete(_ workspace: GitWorkspaceSummary) async {
        await run {
            try await self.engine.gitDeleteWorkspace(
                workspacesDir: Self.reposURL.path,
                name: workspace.name
            )
        }
    }

    func pull(_ workspace: GitWorkspaceSummary) async {
        await run {
            _ = try await self.engine.gitPull(
                workspacesDir: Self.reposURL.path,
                name: workspace.name,
                credentials: Self.storedCredentials()
            )
        }
    }

    func push(_ workspace: GitWorkspaceSummary) async {
        await run {
            _ = try await self.engine.gitPush(
                workspacesDir: Self.reposURL.path,
                name: workspace.name,
                credentials: Self.storedCredentials()
            )
        }
    }

    func commitAll(_ workspace: GitWorkspaceSummary, message: String) async {
        await run {
            _ = try await self.engine.gitCommitAll(
                workspacesDir: Self.reposURL.path,
                name: workspace.name,
                message: message,
                authorName: self.author().name,
                authorEmail: self.author().email
            )
        }
    }

    func branches(_ workspace: GitWorkspaceSummary) async -> [String] {
        (try? await engine.gitBranches(
            workspacesDir: Self.reposURL.path,
            name: workspace.name
        )) ?? []
    }

    func checkout(_ workspace: GitWorkspaceSummary, branch: String, create: Bool) async {
        await run {
            _ = try await self.engine.gitCheckout(
                workspacesDir: Self.reposURL.path,
                name: workspace.name,
                branch: branch,
                create: create
            )
        }
    }

    // MARK: - Commit author identity

    static let authorNameKey = "git-author-name"
    static let authorEmailKey = "git-author-email"

    func author() -> (name: String, email: String) {
        (
            defaults.string(forKey: Self.authorNameKey) ?? "Coven Pocket",
            defaults.string(forKey: Self.authorEmailKey) ?? "pocket@localhost"
        )
    }

    func setAuthor(name: String, email: String) {
        defaults.set(name, forKey: Self.authorNameKey)
        defaults.set(email, forKey: Self.authorEmailKey)
    }

    /// Run one engine operation with busy/error bookkeeping, then reload the
    /// list so summaries (branch, dirty, ahead/behind) stay fresh.
    private func run(_ operation: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }
}

extension GitWorkspaceSummary: Identifiable {
    public var id: String { name }

    /// One-line status: branch plus change/sync markers.
    var statusLine: String {
        var parts = [branch]
        if dirtyCount > 0 { parts.append("\(dirtyCount) changed") }
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.joined(separator: " · ")
    }
}
