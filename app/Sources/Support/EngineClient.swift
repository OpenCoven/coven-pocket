import Foundation

/// Bridges the Rust engine's streaming callbacks onto the main actor and
/// exposes observable state for SwiftUI.
@MainActor
final class EngineClient: ObservableObject {
    @Published var transcript: String = ""
    @Published var thinking: String = ""
    @Published var isStreaming = false
    @Published var errorMessage: String?
    @Published var models: [PocketModel] = []
    @Published var codexModels: [PocketModel] = []
    @Published var codexAccount: CodexAccount?
    @Published var authURL: URL?
    @Published var isAuthenticating = false

    let engine = PocketEngine()

    var engineVersion: String { engine.engineVersion() }
    var defaultModel: String { engine.defaultModel() }
    var defaultCodexModel: String { engine.defaultCodexModel() }

    init() {
        codexAccount = engine.codexAccount()
    }

    // Engine calls run to completion even when the surrounding Swift task is
    // cancelled (the bindings can't cancel in-flight Rust futures), so both
    // loaders re-check cancellation after the await and drop stale outcomes.
    // A successful load also clears any error left by a superseded attempt
    // (e.g. a 401 from a partially-typed key).
    func loadModels(apiKey: String) async {
        do {
            let loaded = try await engine.listModels(apiKey: apiKey)
            guard !Task.isCancelled else { return }
            models = loaded
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadCodexModels() async {
        guard codexAccount != nil else { return }
        do {
            let loaded = try await engine.listCodexModels()
            guard !Task.isCancelled else { return }
            codexModels = loaded
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Run the interactive Codex sign-in. The engine hands back the browser
    /// URL through `AuthBridge`, which publishes `authURL` for the UI to
    /// present; the call resolves once the user finishes (or fails) the flow.
    func codexLogin() async {
        errorMessage = nil
        isAuthenticating = true
        defer {
            isAuthenticating = false
            authURL = nil
        }
        do {
            codexAccount = try await engine.codexLogin(delegate: AuthBridge(client: self))
            await loadCodexModels()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func codexLogout() {
        do {
            try engine.codexLogout()
            codexAccount = nil
            codexModels = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(provider: PocketProvider, apiKey: String, model: String, prompt: String, effort: String?) async {
        transcript = ""
        thinking = ""
        errorMessage = nil
        isStreaming = true
        defer { isStreaming = false }
        do {
            try await engine.streamPrompt(
                provider: provider,
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                effort: effort,
                delegate: StreamBridge(client: self)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Callbacks arrive on Rust worker threads; hop to the main actor.
/// The only mutable state is the ARC-managed weak reference, which is
/// thread-safe to read, so `@unchecked Sendable` holds.
private final class StreamBridge: StreamDelegate, @unchecked Sendable {
    weak var client: EngineClient?

    init(client: EngineClient) {
        self.client = client
    }

    func onText(text: String) {
        Task { @MainActor [client] in client?.transcript += text }
    }

    func onThinking(text: String) {
        Task { @MainActor [client] in client?.thinking += text }
    }

    func onDone(stopReason: String) {}

    func onError(message: String) {
        Task { @MainActor [client] in client?.errorMessage = message }
    }
}

/// Login-flow callbacks arrive on Rust worker threads; hop to the main actor.
/// Same `@unchecked Sendable` justification as `StreamBridge`.
private final class AuthBridge: CodexAuthDelegate, @unchecked Sendable {
    weak var client: EngineClient?

    init(client: EngineClient) {
        self.client = client
    }

    func onAuthUrl(url: String) {
        Task { @MainActor [client] in client?.authURL = URL(string: url) }
    }
}
