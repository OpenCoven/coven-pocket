import Foundation

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

    let id = UUID()
    let kind: Kind
    var text: String
    var tool: ToolCallInfo?

    init(kind: Kind, text: String, tool: ToolCallInfo? = nil) {
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

/// Settings a chat session is bound to. Changing any of them requires a new
/// engine session (the transcript restarts).
struct ChatSettings: Equatable {
    var provider: PocketProvider = .anthropic
    var apiKey: String = ""
    var model: String = ""
    var effort: String = "medium"
}

/// Drives the agentic chat surface: owns the engine session, the rendered
/// transcript, and the delegate bridge from Rust callback threads.
@MainActor
final class ChatModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var isBusy = false
    @Published var canRetry = false

    let engine = PocketEngine()

    private var session: ChatSession?
    private var sessionSettings: ChatSettings?

    /// The on-device directory the agent is allowed to touch. Files created
    /// here are visible in the Files app via the app's Documents folder.
    static var workspaceURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workspace", isDirectory: true)
    }

    func send(prompt: String, settings: ChatSettings) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }

        canRetry = false
        do {
            let session = try activeSession(for: settings)
            items.append(ChatItem(kind: .user, text: trimmed))
            isBusy = true
            defer { isBusy = false }
            try await session.send(prompt: trimmed, delegate: ChatBridge(model: self))
        } catch {
            appendError(error.localizedDescription)
        }
    }

    /// Re-run the last failed turn without repeating the user message.
    func retry() async {
        guard let session, canRetry, !isBusy else { return }
        canRetry = false
        isBusy = true
        defer { isBusy = false }
        do {
            try await session.retry(delegate: ChatBridge(model: self))
        } catch {
            appendError(error.localizedDescription)
        }
    }

    func stop() {
        session?.stop()
    }

    /// Discard the session and transcript (e.g. after changing settings).
    func reset() {
        stop()
        session = nil
        sessionSettings = nil
        items = []
        canRetry = false
    }

    /// Reuse the live session when settings are unchanged; otherwise start a
    /// fresh one bound to the app workspace directory.
    private func activeSession(for settings: ChatSettings) throws -> ChatSession {
        if let session, sessionSettings == settings {
            return session
        }
        let workspace = Self.workspaceURL
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        items = []
        let fresh = try engine.startChat(
            provider: settings.provider,
            apiKey: settings.apiKey,
            model: settings.model,
            effort: settings.effort,
            workspaceDir: workspace.path
        )
        session = fresh
        sessionSettings = settings
        return fresh
    }

    // MARK: - Bridge entry points (already on the main actor)

    func appendAssistantText(_ delta: String) {
        if let last = items.indices.last, items[last].kind == .assistant {
            items[last].text += delta
        } else {
            items.append(ChatItem(kind: .assistant, text: delta))
        }
    }

    func appendThinking(_ delta: String) {
        if let last = items.indices.last, items[last].kind == .thinking {
            items[last].text += delta
        } else {
            items.append(ChatItem(kind: .thinking, text: delta))
        }
    }

    func beginTool(id: String, name: String, inputJson: String) {
        let info = ToolCallInfo(
            toolId: id,
            name: name,
            inputSummary: Self.summarizeToolInput(name: name, json: inputJson)
        )
        items.append(ChatItem(kind: .tool, text: name, tool: info))
    }

    func endTool(id: String, result: String, isError: Bool) {
        guard let index = items.lastIndex(where: { $0.tool?.toolId == id }) else { return }
        items[index].tool?.result = result
        items[index].tool?.isError = isError
        items[index].tool?.isRunning = false
    }

    func appendStatus(_ message: String) {
        items.append(ChatItem(kind: .status, text: message))
    }

    func finishTurn(stopReason: String) {
        if stopReason == "cancelled" {
            appendStatus("Stopped.")
        }
    }

    func appendError(_ message: String) {
        items.append(ChatItem(kind: .error, text: message))
        canRetry = true
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

    /// Trim the sandbox prefix so cards show workspace-relative paths.
    private static func shortenWorkspacePath(_ path: String) -> String {
        let prefix = workspaceURL.path
        if path.hasPrefix(prefix) {
            let trimmed = path.dropFirst(prefix.count).drop(while: { $0 == "/" })
            return trimmed.isEmpty ? "workspace" : String(trimmed)
        }
        return path
    }
}

/// Chat callbacks arrive on Rust worker threads; hop to the main actor.
/// The only mutable state is the ARC-managed weak reference, which is
/// thread-safe to read, so `@unchecked Sendable` holds.
private final class ChatBridge: ChatDelegate, @unchecked Sendable {
    weak var model: ChatModel?

    init(model: ChatModel) {
        self.model = model
    }

    func onText(text: String) {
        Task { @MainActor [model] in model?.appendAssistantText(text) }
    }

    func onThinking(text: String) {
        Task { @MainActor [model] in model?.appendThinking(text) }
    }

    func onToolStart(toolId: String, toolName: String, inputJson: String) {
        Task { @MainActor [model] in
            model?.beginTool(id: toolId, name: toolName, inputJson: inputJson)
        }
    }

    func onToolEnd(toolId: String, toolName: String, result: String, isError: Bool) {
        Task { @MainActor [model] in
            model?.endTool(id: toolId, result: result, isError: isError)
        }
    }

    func onStatus(message: String) {
        Task { @MainActor [model] in model?.appendStatus(message) }
    }

    func onDone(stopReason: String) {
        Task { @MainActor [model] in model?.finishTurn(stopReason: stopReason) }
    }

    func onError(message: String) {
        Task { @MainActor [model] in model?.appendError(message) }
    }
}
