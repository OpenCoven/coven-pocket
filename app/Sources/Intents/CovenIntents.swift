import AppIntents
import Foundation

/// A cloned git workspace, exposed so Shortcuts can pick where a prompt
/// runs. Identity is the absolute path ChatModel binds sessions to.
struct WorkspaceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workspace")
    static let defaultQuery = WorkspaceQuery()

    /// Absolute workspace path.
    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    /// Directories under the repos root, one entity per cloned workspace.
    /// Filesystem-only on purpose: intent queries must stay fast and cannot
    /// assume the engine is warm.
    static func workspaces(under reposRoot: URL) -> [WorkspaceEntity] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: reposRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { WorkspaceEntity(id: $0.standardizedFileURL.path, name: $0.lastPathComponent) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct WorkspaceQuery: EntityQuery {
    // RepoModel is main-actor isolated; hop there for the repos root.
    @MainActor
    func entities(for identifiers: [String]) async throws -> [WorkspaceEntity] {
        WorkspaceEntity.workspaces(under: RepoModel.reposURL)
            .filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [WorkspaceEntity] {
        WorkspaceEntity.workspaces(under: RepoModel.reposURL)
    }
}

/// The shared effects behind the intents, factored out so tests can drive
/// them without instantiating AppIntents machinery.
@MainActor
enum IntentActions {
    /// Queue `prompt` for the chat tab, optionally rebinding the active
    /// workspace first (same keys ReposView writes).
    static func ask(
        prompt: String,
        workspace: WorkspaceEntity?,
        router: AppRouter,
        defaults: UserDefaults
    ) {
        if let workspace {
            defaults.set(workspace.id, forKey: ChatModel.activeWorkspacePathKey)
            defaults.set(workspace.name, forKey: RepoModel.activeRepoNameKey)
        }
        router.openChat(prompt: prompt)
    }

    static func startFresh(router: AppRouter) {
        router.startFreshChat()
    }
}

/// "Ask Coven Pocket <prompt>": opens the app on the chat tab and sends the
/// prompt to the agent (or pre-fills it when provider settings are missing).
struct AskCovenIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask the Agent"
    static let description = IntentDescription(
        "Send a prompt to the on-device coding agent, optionally in a specific workspace."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Prompt", inputOptions: String.IntentInputOptions(multiline: true))
    var prompt: String

    @Parameter(title: "Workspace")
    var workspace: WorkspaceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$prompt) in \(\.$workspace)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentActions.ask(
            prompt: prompt,
            workspace: workspace,
            router: .shared,
            defaults: .standard
        )
        return .result()
    }
}

/// "Start a new session": opens the chat tab with a cleared conversation.
struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start New Session"
    static let description = IntentDescription(
        "Open the chat tab with a fresh conversation."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentActions.startFresh(router: .shared)
        return .result()
    }
}

/// System-visible shortcut phrases (Siri, Spotlight, the Shortcuts app).
struct CovenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskCovenIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) to code"
            ],
            shortTitle: "Ask the Agent",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: StartSessionIntent(),
            phrases: [
                "Start a \(.applicationName) session",
                "New \(.applicationName) session"
            ],
            shortTitle: "New Session",
            systemImageName: "plus.bubble"
        )
    }
}
