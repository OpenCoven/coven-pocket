import Foundation

private struct FamiliarUnavailableError: LocalizedError {
    var errorDescription: String? {
        "The selected familiar is no longer available."
    }
}

private struct ActiveSessionDeletionError: LocalizedError {
    var errorDescription: String? {
        "Start a new chat before deleting the active session."
    }
}

private struct BusySessionDeletionError: LocalizedError {
    var errorDescription: String? {
        "Finish the current chat operation before deleting sessions."
    }
}

// Session lifecycle state intentionally stays with the main-actor model.
// swiftlint:disable file_length

/// One rendered row in the chat transcript.
struct ChatItem: Identifiable {
    enum Kind {
        case user
        case assistant
        case thinking
        case status
        case error
        case tool
    }

    let id: String
    let kind: Kind
    var text: String
    var tool: ToolCallInfo?

    init(
        id: String = UUID().uuidString,
        kind: Kind,
        text: String,
        tool: ToolCallInfo? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.tool = tool
    }
}

/// State of a single tool invocation, rendered as a card.
struct ToolCallInfo {
    let toolId: String
    let name: String
    let inputSummary: String
    var result: String?
    var isError = false
    var isRunning = true
}

/// Drives the agentic chat surface: owns the engine session, the rendered
/// transcript, and the delegate bridge from Rust callback threads.
@MainActor
// swiftlint:disable:next type_body_length
final class ChatModel: ObservableObject {
    enum SessionOperationKind: Equatable {
        case start(familiar: FamiliarIdentity?)
        case resume
    }

    typealias SessionOperation = @MainActor (
        SessionOperationKind,
        @MainActor () async throws -> ChatSession
    ) async throws -> ChatSession

    @Published var items: [ChatItem] = []
    @Published var isBusy = false
    @Published var canRetry = false
    @Published private(set) var activeFamiliar: FamiliarIdentity?
    @Published private(set) var activeSessionID: String?
    /// The approval sheet currently on screen, if any.
    @Published var pendingApproval: PendingApproval?
    /// Applies to the live session immediately; changing it never restarts
    /// the conversation.
    @Published var permissionMode: ChatPermissionMode {
        didSet {
            session?.setPermissionMode(mode: permissionMode)
            defaults.set(permissionMode.storageValue, forKey: Self.permissionModeKey)
        }
    }

    let engine: PocketEngine

    private var session: ChatSession?
    private var sessionSettings: ChatSettings?
    private var sessionReplacementSettings: ChatSettings?
    private var sessionWorkspace: String?
    private var transcriptGeneration: UInt64 = 0
    private var operationGeneration: UInt64 = 0
    private var activeOperationGeneration: UInt64?
    private var activeOperationSession: ChatSession?
    private var approvalQueue: [PendingApproval] = []
    private let defaults: UserDefaults
    private let performSessionOperation: SessionOperation
    private let storedSessionsLoader: SessionListModel.Loader

    static let permissionModeKey = "chat-permission-mode"
    /// Absolute path of the git workspace chat should operate in, written by
    /// the Repos tab. Missing or stale paths fall back to the scratch dir.
    static let activeWorkspacePathKey = "active-workspace-path"

    /// Project memory is a per-workspace choice: rules written for one repo
    /// shouldn't leak into another.
    static func injectContextKey(forWorkspace path: String) -> String {
        "inject-context:\(path)"
    }

    /// Whether new sessions prepend the workspace's AGENTS.md chain and
    /// memory notes to the system prompt. Applies from the next session.
    var injectContext: Bool {
        get { defaults.bool(forKey: Self.injectContextKey(forWorkspace: effectiveWorkspaceURL.path)) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.injectContextKey(forWorkspace: effectiveWorkspaceURL.path))
        }
    }

    init(
        defaults: UserDefaults = .standard,
        performSessionOperation: @escaping SessionOperation = { _, operation in
            try await operation()
        },
        storedSessionsLoader: SessionListModel.Loader? = nil
    ) {
        let engine = PocketEngine()
        self.engine = engine
        self.defaults = defaults
        self.performSessionOperation = performSessionOperation
        self.storedSessionsLoader = storedSessionsLoader ?? {
            try await engine.listChatSessions(
                storageDir: Self.sessionStoreURL.path
            )
        }
        permissionMode = ChatPermissionMode(
            storageValue: defaults.string(forKey: Self.permissionModeKey)
        )
    }

    /// The on-device directory the agent is allowed to touch. Files created
    /// here are visible in the Files app via the app's Documents folder.
    static var workspaceURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workspace", isDirectory: true)
    }

    /// Where transcripts and the session index live: app data, not user
    /// documents, so it stays out of the Files app.
    static var sessionStoreURL: URL {
        sessionStoreURL(
            applicationSupportBase: FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
        )
    }

    static func sessionStoreURL(applicationSupportBase: URL) -> URL {
        let resolvedBase = applicationSupportBase
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL

        return canonicalAppleSystemRootAlias(resolvedBase)
            .appendingPathComponent("chat-sessions", isDirectory: true)
    }

    private static func canonicalAppleSystemRootAlias(_ url: URL) -> URL {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let path = url.path
        let aliases = [
            (alias: "/var", canonical: "/private/var"),
            (alias: "/tmp", canonical: "/private/tmp"),
            (alias: "/etc", canonical: "/private/etc")
        ]

        for mapping in aliases
        where path == mapping.alias || path.hasPrefix("\(mapping.alias)/") {
            let suffix = path.dropFirst(mapping.alias.count)
            return URL(
                fileURLWithPath: mapping.canonical + suffix,
                isDirectory: url.hasDirectoryPath
            )
        }
        #endif

        return url
    }

    /// The directory the next session binds to: the active git workspace
    /// when one is selected and still a directory on disk, else the scratch
    /// workspace.
    var effectiveWorkspaceURL: URL {
        if let path = defaults.string(forKey: Self.activeWorkspacePathKey) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
        }
        return Self.workspaceURL
    }

    var hasActiveSession: Bool {
        session != nil
    }

    func send(
        prompt: String,
        settings: ChatSettings,
        selectedFamiliar: FamiliarIdentity? = nil
    ) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let generation = claimOperation()
        else { return }
        defer { finishOperation(generation: generation) }

        canRetry = false
        do {
            guard let session = try await activeSession(
                for: settings,
                selectedFamiliar: selectedFamiliar,
                generation: generation
            ), setOperationSession(session, generation: generation) else { return }
            items.append(ChatItem(kind: .user, text: trimmed))
            try await session.send(
                prompt: trimmed,
                delegate: GenerationChatBridge(
                    model: self,
                    generation: transcriptGeneration
                )
            )
        } catch {
            guard isCurrentOperation(generation: generation) else { return }
            let retryable = activeOperationSession != nil
            appendError(error.localizedDescription)
            canRetry = retryable
        }
    }

    /// Re-run the last failed turn without repeating the user message.
    func retry() async {
        guard let session,
              canRetry,
              let generation = claimOperation(session: session)
        else { return }
        defer { finishOperation(generation: generation) }

        canRetry = false
        do {
            try await session.retry(
                delegate: GenerationChatBridge(
                    model: self,
                    generation: transcriptGeneration
                )
            )
        } catch {
            guard isCurrentOperation(generation: generation) else { return }
            appendError(error.localizedDescription)
        }
    }

    func stop() {
        guard let generation = activeOperationGeneration else {
            session?.stop()
            return
        }
        if let runningSession = activeOperationSession {
            runningSession.stop()
        } else {
            invalidateOperation(generation: generation)
        }
    }

    /// Discard the session and transcript (e.g. after changing settings).
    func reset() {
        let runningSession = invalidateOperation()
        transcriptGeneration &+= 1
        (runningSession ?? session)?.stop()
        clearSessionState()
    }

    private func clearSessionState() {
        session = nil
        sessionSettings = nil
        sessionReplacementSettings = nil
        sessionWorkspace = nil
        activeFamiliar = nil
        activeSessionID = nil
        items = []
        canRetry = false
        // Dropping unanswered responders denies their tool calls.
        pendingApproval = nil
        approvalQueue = []
    }

    /// Reuse the live session when settings and workspace are unchanged;
    /// otherwise start a fresh one bound to the effective workspace.
    private func activeSession(
        for settings: ChatSettings,
        selectedFamiliar: FamiliarIdentity?,
        generation: UInt64
    ) async throws -> ChatSession? {
        guard isCurrentOperation(generation: generation) else { return nil }
        let workspace = effectiveWorkspaceURL
        if let session,
           sessionReplacementSettings == settings,
           sessionWorkspace == workspace.path {
            return session
        }
        let familiar = try Self.resolvedFamiliar(
            for: settings,
            selectedFamiliar: selectedFamiliar
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let permissionMode = permissionMode
        let injectContext = injectContext
        let engine = engine
        let fresh = try await performSessionOperation(
            .start(familiar: familiar)
        ) {
            try await engine.startChat(
                provider: .codex,
                apiKey: "",
                model: settings.model,
                effort: nil,
                workspaceDir: workspace.path,
                permissionMode: permissionMode,
                storageDir: Self.sessionStoreURL.path,
                familiar: familiar,
                injectContext: injectContext
            )
        }
        guard isCurrentOperation(generation: generation) else {
            fresh.stop()
            return nil
        }

        transcriptGeneration &+= 1
        items = []
        session = fresh
        sessionSettings = settings
        sessionReplacementSettings = settings
        sessionWorkspace = workspace.path
        activeFamiliar = familiar
        activeSessionID = fresh.sessionId()
        return fresh
    }

    nonisolated static func resolvedFamiliar(
        for settings: ChatSettings,
        selectedFamiliar: FamiliarIdentity?
    ) throws -> FamiliarIdentity? {
        guard let familiarID = settings.familiarID else { return nil }
        guard let selectedFamiliar,
              familiarID.caseInsensitiveCompare(selectedFamiliar.id) == .orderedSame
        else {
            throw FamiliarUnavailableError()
        }
        return selectedFamiliar
    }

    // MARK: - Session browser

    /// Stored sessions, newest first. The engine call is async, keeping the
    /// SQLite read off the main thread.
    func storedSessions() async throws -> [ChatSessionSummary] {
        try await storedSessionsLoader()
    }

    /// Swap the live conversation for a stored one, restoring its transcript.
    func resume(
        _ summary: ChatSessionSummary,
        settings: ChatSettings
    ) async -> Bool {
        guard let generation = claimOperation() else { return false }
        defer { finishOperation(generation: generation) }
        if session != nil, activeSessionID == summary.sessionId {
            return true
        }

        do {
            let resumedSettings = Self.settingsForResume(
                summary,
                current: settings
            )
            let workspace = effectiveWorkspaceURL
            try FileManager.default.createDirectory(
                at: workspace, withIntermediateDirectories: true
            )
            let resumed = try await resumedSession(
                summary,
                settings: resumedSettings,
                workspace: workspace
            )
            guard isCurrentOperation(generation: generation) else {
                resumed.stop()
                return false
            }
            let transcript = await resumed.transcript()
            guard isCurrentOperation(generation: generation) else {
                resumed.stop()
                return false
            }

            transcriptGeneration &+= 1
            session?.stop()
            clearSessionState()
            session = resumed
            sessionSettings = resumedSettings
            sessionReplacementSettings = settings
            sessionWorkspace = workspace.path
            activeFamiliar = summary.familiar
            activeSessionID = summary.sessionId
            items = Self.items(fromTranscript: transcript)
            return true
        } catch {
            guard isCurrentOperation(generation: generation) else {
                return false
            }
            appendError(error.localizedDescription)
            canRetry = false
            return false
        }
    }

    private func resumedSession(
        _ summary: ChatSessionSummary,
        settings: ChatSettings,
        workspace: URL
    ) async throws -> ChatSession {
        let permissionMode = permissionMode
        let injectContext = injectContext
        let engine = engine
        return try await performSessionOperation(.resume) {
            try await engine.resumeChat(
                provider: .codex,
                apiKey: "",
                model: settings.model,
                effort: nil,
                workspaceDir: workspace.path,
                permissionMode: permissionMode,
                storageDir: Self.sessionStoreURL.path,
                sessionId: summary.sessionId,
                injectContext: injectContext
            )
        }
    }

    nonisolated static func settingsForResume(
        _ summary: ChatSessionSummary,
        current: ChatSettings
    ) -> ChatSettings {
        var settings = current
        settings.familiarID = summary.familiar?.id
        return settings
    }

    private func claimOperation(session: ChatSession? = nil) -> UInt64? {
        guard activeOperationGeneration == nil, !isBusy else { return nil }
        operationGeneration &+= 1
        activeOperationGeneration = operationGeneration
        activeOperationSession = session
        isBusy = true
        return operationGeneration
    }

    private func setOperationSession(_ session: ChatSession, generation: UInt64) -> Bool {
        guard activeOperationGeneration == generation else { return false }
        activeOperationSession = session
        return true
    }

    private func isCurrentOperation(generation: UInt64) -> Bool {
        activeOperationGeneration == generation
    }

    private func finishOperation(generation: UInt64) {
        guard activeOperationGeneration == generation else { return }
        activeOperationGeneration = nil
        activeOperationSession = nil
        isBusy = false
    }

    @discardableResult
    private func invalidateOperation(generation: UInt64? = nil) -> ChatSession? {
        guard let activeGeneration = activeOperationGeneration,
              generation == nil || generation == activeGeneration
        else { return nil }

        let runningSession = activeOperationSession
        activeOperationGeneration = nil
        activeOperationSession = nil
        isBusy = false
        return runningSession
    }

    func canDeleteSession(_ summary: ChatSessionSummary) -> Bool {
        !isBusy && activeSessionID != summary.sessionId
    }

    func deleteSession(_ summary: ChatSessionSummary) async throws {
        guard !isBusy else {
            throw BusySessionDeletionError()
        }
        guard canDeleteSession(summary) else {
            throw ActiveSessionDeletionError()
        }
        try await engine.deleteChatSession(
            storageDir: Self.sessionStoreURL.path,
            sessionId: summary.sessionId
        )
    }

    /// Copy a stored session at its head.
    func forkSession(_ summary: ChatSessionSummary) async throws {
        _ = try await engine.forkChatSession(
            storageDir: Self.sessionStoreURL.path,
            sessionId: summary.sessionId
        )
    }

    /// Rendered rows for a restored transcript.
    static func items(fromTranscript transcript: [ChatMessage]) -> [ChatItem] {
        transcript.map { message in
            ChatItem(
                kind: message.role == "assistant" ? .assistant : .user,
                text: message.text
            )
        }
    }

    // MARK: - Bridge entry points (already on the main actor)

    func appendAssistantText(_ delta: String, generation: UInt64? = nil) {
        guard acceptsTranscriptCallback(generation: generation) else { return }
        if let last = items.indices.last, items[last].kind == .assistant {
            items[last].text += delta
        } else {
            items.append(ChatItem(kind: .assistant, text: delta))
        }
    }

    func appendThinking(_ delta: String, generation: UInt64? = nil) {
        guard acceptsTranscriptCallback(generation: generation) else { return }
        if let last = items.indices.last, items[last].kind == .thinking {
            items[last].text += delta
        } else {
            items.append(ChatItem(kind: .thinking, text: delta))
        }
    }

    func beginTool(
        id: String,
        name: String,
        inputJson: String,
        generation: UInt64? = nil
    ) {
        guard acceptsTranscriptCallback(generation: generation) else { return }
        let info = ToolCallInfo(
            toolId: id,
            name: name,
            inputSummary: Self.summarizeToolInput(name: name, json: inputJson)
        )
        items.append(ChatItem(kind: .tool, text: name, tool: info))
    }

    func endTool(
        id: String,
        result: String,
        isError: Bool,
        generation: UInt64? = nil
    ) {
        guard acceptsTranscriptCallback(generation: generation) else { return }
        guard let index = items.lastIndex(where: { $0.tool?.toolId == id }) else { return }
        items[index].tool?.result = result
        items[index].tool?.isError = isError
        items[index].tool?.isRunning = false
    }

    func appendStatus(_ message: String, generation: UInt64? = nil) {
        guard acceptsTranscriptCallback(generation: generation) else { return }
        items.append(ChatItem(kind: .status, text: message))
    }

    func finishTurn(stopReason: String, generation: UInt64? = nil) {
        guard acceptsTranscriptCallback(generation: generation) else { return }
        if stopReason == "cancelled" {
            appendStatus("Stopped.")
        }
    }

    func appendError(_ message: String, generation: UInt64? = nil) {
        guard acceptsTranscriptCallback(generation: generation) else { return }
        items.append(ChatItem(kind: .error, text: message))
        canRetry = session != nil
    }

    private func acceptsTranscriptCallback(generation: UInt64?) -> Bool {
        generation == nil || generation == transcriptGeneration
    }

    // MARK: - Approvals

    /// Show the request, or queue it behind the one already on screen.
    func receiveApproval(_ approval: PendingApproval, generation: UInt64? = nil) {
        guard acceptsTranscriptCallback(generation: generation) else { return }
        if pendingApproval == nil {
            pendingApproval = approval
        } else {
            approvalQueue.append(approval)
        }
    }

    private final class GenerationChatBridge: ChatDelegate, @unchecked Sendable {
        weak var model: ChatModel?
        private let generation: UInt64

        init(model: ChatModel, generation: UInt64) {
            self.model = model
            self.generation = generation
        }

        private func publish(
            _ update: @escaping @MainActor @Sendable (ChatModel, UInt64) -> Void
        ) {
            Task { @MainActor [model, generation] in
                guard let model else { return }
                update(model, generation)
            }
        }

        func onText(text: String) {
            publish { model, generation in
                model.appendAssistantText(text, generation: generation)
            }
        }

        func onThinking(text: String) {
            publish { model, generation in
                model.appendThinking(text, generation: generation)
            }
        }

        func onToolStart(toolId: String, toolName: String, inputJson: String) {
            publish { model, generation in
                model.beginTool(
                    id: toolId,
                    name: toolName,
                    inputJson: inputJson,
                    generation: generation
                )
            }
        }

        func onToolEnd(toolId: String, toolName: String, result: String, isError: Bool) {
            publish { model, generation in
                model.endTool(
                    id: toolId,
                    result: result,
                    isError: isError,
                    generation: generation
                )
            }
        }

        func onStatus(message: String) {
            publish { model, generation in
                model.appendStatus(message, generation: generation)
            }
        }

        func onPermissionRequest(request: ChatPermissionRequest, responder: ChatPermissionResponder) {
            publish { model, generation in
                model.receiveApproval(
                    PendingApproval(request: request, responder: responder),
                    generation: generation
                )
            }
        }

        func onDone(stopReason: String) {
            publish { model, generation in
                model.finishTurn(stopReason: stopReason, generation: generation)
            }
        }

        func onError(message: String) {
            publish { model, generation in
                model.appendError(message, generation: generation)
            }
        }
    }

    /// Deliver the user's decision and dismiss the sheet.
    func respond(to approval: PendingApproval, decision: ChatPermissionDecision) {
        approval.responder.respond(decision: decision)
        if pendingApproval?.id == approval.id {
            pendingApproval = nil
        }
    }

    /// Sheet dismissed (answered or swiped away — an unanswered responder
    /// denies on release). Surface the next queued request, if any.
    func approvalDismissed() {
        guard pendingApproval == nil, !approvalQueue.isEmpty else { return }
        pendingApproval = approvalQueue.removeFirst()
    }

    /// Compact, human-readable summary of a tool call's input.
    static func summarizeToolInput(name: String, json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }

        let pathKeys = ["file_path", "notebook_path", "path", "pattern"]
        for key in pathKeys {
            if let value = object[key] as? String, !value.isEmpty {
                return shortenWorkspacePath(value)
            }
        }
        if name == "BatchEdit", let edits = object["edits"] as? [[String: Any]] {
            let paths = edits.compactMap { $0["file_path"] as? String }
            let unique = Array(Set(paths.map(shortenWorkspacePath))).sorted()
            return unique.joined(separator: ", ")
        }
        return ""
    }

    /// Trim sandbox prefixes so cards show workspace-relative paths.
    private static func shortenWorkspacePath(_ path: String) -> String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for prefix in [workspaceURL.path, documents.path] where path.hasPrefix(prefix) {
            let trimmed = path.dropFirst(prefix.count).drop(while: { $0 == "/" })
            return trimmed.isEmpty ? "workspace" : String(trimmed)
        }
        return path
    }
}
