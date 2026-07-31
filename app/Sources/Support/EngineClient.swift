import Foundation

private struct StreamOperationToken: Equatable, Sendable {
    enum AccountScope: Equatable, Sendable {
        case unrelatedToCodex
        case codex(profileID: String?)
    }

    let generation: UInt64
    let accountScope: AccountScope
}

private struct PendingAuthenticationSlot {
    let generation: UInt64
    let continuation: CheckedContinuation<Bool, Never>
}

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
    @Published var codexAccount: CodexAccount? {
        didSet {
            guard oldValue?.profileId != codexAccount?.profileId else { return }
            codexModels = []
            codexModelLoadGeneration &+= 1
            invalidateCurrentCodexStream()
        }
    }
    @Published var authURL: URL?
    @Published var isAuthenticating = false

    let engine: any EngineClientEngine

    private var streamGeneration: UInt64 = 0
    private var currentStream: StreamOperationToken?
    private var activeStream: StreamOperationToken?
    private var authGeneration: UInt64 = 0
    private var activeAuthGeneration: UInt64?
    // Rust login owns a fixed callback port and outlives Swift cancellation.
    private var isAuthenticationEngineInFlight = false
    private var pendingAuthenticationSlot: PendingAuthenticationSlot?
    private var isAuthenticationCleanupRequired = false
    private var modelLoadGeneration: UInt64 = 0
    private var codexModelLoadGeneration: UInt64 = 0

    var engineVersion: String { engine.engineVersion() }
    var defaultModel: String { engine.defaultModel() }
    var defaultCodexModel: String { engine.defaultCodexModel() }

    init(engine: any EngineClientEngine = PocketEngine()) {
        self.engine = engine
        codexAccount = engine.codexAccount()
    }

    // Engine calls run to completion even when the surrounding Swift task is
    // cancelled (the bindings can't cancel in-flight Rust futures), so both
    // loaders re-check cancellation after the await and drop stale outcomes.
    // A successful load also clears any error left by a superseded attempt
    // (e.g. a 401 from a partially-typed key).
    func loadModels(apiKey: String) async {
        modelLoadGeneration &+= 1
        let generation = modelLoadGeneration
        do {
            let loaded = try await engine.listModels(apiKey: apiKey)
            guard !Task.isCancelled,
                  modelLoadGeneration == generation
            else { return }
            models = loaded
            errorMessage = nil
        } catch {
            guard !Task.isCancelled,
                  modelLoadGeneration == generation
            else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadCodexModels() async {
        guard let profileID = codexAccount?.profileId else { return }
        codexModelLoadGeneration &+= 1
        let generation = codexModelLoadGeneration
        do {
            let loaded = try await engine.listCodexModels()
            guard !Task.isCancelled,
                  codexModelLoadGeneration == generation,
                  codexAccount?.profileId == profileID
            else { return }
            codexModels = loaded
            errorMessage = nil
        } catch {
            guard !Task.isCancelled,
                  codexModelLoadGeneration == generation,
                  codexAccount?.profileId == profileID
            else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Run the interactive Codex sign-in. The engine hands back the browser
    /// URL through `AuthBridge`, which publishes `authURL` for the UI to
    /// present; the call resolves once the user finishes (or fails) the flow.
    func codexLogin() async {
        guard activeAuthGeneration == nil else { return }
        authGeneration &+= 1
        let generation = authGeneration
        activeAuthGeneration = generation
        errorMessage = nil
        authURL = nil
        isAuthenticating = true
        defer { finishAuthentication(generation: generation) }
        guard await acquireAuthenticationSlot(generation: generation) else {
            return
        }
        guard isCurrentAuthentication(generation) else {
            releaseAuthenticationSlot()
            return
        }
        guard prepareAuthenticationEngine(generation: generation) else {
            releaseAuthenticationSlot()
            return
        }
        let result: Result<CodexAccount, Error>
        do {
            result = .success(try await engine.codexLogin(
                delegate: AuthBridge(client: self, generation: generation)
            ))
        } catch {
            result = .failure(error)
        }
        let isCurrent = isCurrentAuthentication(generation)
        if !isCurrent, case .success = result {
            do {
                try engine.codexLogout()
                isAuthenticationCleanupRequired = false
            } catch {
                isAuthenticationCleanupRequired = true
            }
        }
        releaseAuthenticationSlot()
        guard isCurrent else { return }
        switch result {
        case let .success(account):
            codexAccount = account
            await loadCodexModels()
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    func codexLogout() {
        invalidateAuthentication()
        do {
            try engine.codexLogout()
            isAuthenticationCleanupRequired = false
            codexAccount = nil
        } catch {
            isAuthenticationCleanupRequired = true
            errorMessage = error.localizedDescription
        }
    }

    func send(provider: PocketProvider, apiKey: String, model: String, prompt: String, effort: String?) async {
        guard !isStreaming, activeStream == nil else { return }
        streamGeneration &+= 1
        let token = StreamOperationToken(
            generation: streamGeneration,
            accountScope: provider == .codex
                ? .codex(profileID: codexAccount?.profileId)
                : .unrelatedToCodex
        )
        currentStream = token
        activeStream = token
        transcript = ""
        thinking = ""
        errorMessage = nil
        isStreaming = true
        defer { finishStream(token) }
        do {
            try await engine.streamPrompt(
                provider: provider,
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                effort: effort,
                delegate: StreamBridge(client: self, token: token)
            )
        } catch {
            guard isCurrentStream(token) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

extension EngineClient {
    fileprivate func appendText(
        _ text: String,
        for token: StreamOperationToken
    ) {
        guard isCurrentStream(token) else { return }
        transcript += text
    }

    fileprivate func appendThinking(
        _ text: String,
        for token: StreamOperationToken
    ) {
        guard isCurrentStream(token) else { return }
        thinking += text
    }

    fileprivate func publishStreamError(
        _ message: String,
        for token: StreamOperationToken
    ) {
        guard isCurrentStream(token) else { return }
        errorMessage = message
    }

    fileprivate func publishAuthURL(
        _ url: String,
        generation: UInt64
    ) {
        guard isCurrentAuthentication(generation) else { return }
        authURL = URL(string: url)
    }

    private func isCurrentStream(_ token: StreamOperationToken) -> Bool {
        guard currentStream == token,
              streamGeneration == token.generation
        else { return false }
        switch token.accountScope {
        case .unrelatedToCodex:
            return true
        case let .codex(profileID):
            return codexAccount?.profileId == profileID
        }
    }

    private func finishStream(_ token: StreamOperationToken) {
        guard activeStream == token, isCurrentStream(token) else { return }
        activeStream = nil
        isStreaming = false
    }

    private func invalidateCurrentCodexStream() {
        guard let token = currentStream,
              case .codex = token.accountScope
        else { return }
        streamGeneration &+= 1
        currentStream = nil
        if activeStream == token {
            activeStream = nil
            isStreaming = false
        }
        transcript = ""
        thinking = ""
        errorMessage = nil
    }

    private func isCurrentAuthentication(_ generation: UInt64) -> Bool {
        activeAuthGeneration == generation
    }

    private func finishAuthentication(generation: UInt64) {
        guard isCurrentAuthentication(generation) else { return }
        activeAuthGeneration = nil
        isAuthenticating = false
        authURL = nil
    }

    private func invalidateAuthentication() {
        if let pending = pendingAuthenticationSlot {
            pendingAuthenticationSlot = nil
            pending.continuation.resume(returning: false)
        }
        authGeneration &+= 1
        activeAuthGeneration = nil
        isAuthenticating = false
        authURL = nil
    }

    private func acquireAuthenticationSlot(
        generation: UInt64
    ) async -> Bool {
        guard isCurrentAuthentication(generation) else { return false }
        guard isAuthenticationEngineInFlight else {
            isAuthenticationEngineInFlight = true
            return true
        }
        return await withCheckedContinuation { continuation in
            guard isCurrentAuthentication(generation) else {
                continuation.resume(returning: false)
                return
            }
            pendingAuthenticationSlot = PendingAuthenticationSlot(
                generation: generation,
                continuation: continuation
            )
        }
    }

    private func releaseAuthenticationSlot() {
        guard let pending = pendingAuthenticationSlot else {
            isAuthenticationEngineInFlight = false
            return
        }
        pendingAuthenticationSlot = nil
        guard isCurrentAuthentication(pending.generation) else {
            isAuthenticationEngineInFlight = false
            pending.continuation.resume(returning: false)
            return
        }
        pending.continuation.resume(returning: true)
    }

    private func prepareAuthenticationEngine(
        generation: UInt64
    ) -> Bool {
        guard isAuthenticationCleanupRequired else { return true }
        do {
            try engine.codexLogout()
            isAuthenticationCleanupRequired = false
            return true
        } catch {
            guard isCurrentAuthentication(generation) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// Callbacks arrive on Rust worker threads; hop to the main actor.
/// The only mutable state is the ARC-managed weak reference, which is
/// thread-safe to read, so `@unchecked Sendable` holds.
private final class StreamBridge: StreamDelegate, @unchecked Sendable {
    weak var client: EngineClient?
    let token: StreamOperationToken

    init(client: EngineClient, token: StreamOperationToken) {
        self.client = client
        self.token = token
    }

    func onText(text: String) {
        Task { @MainActor [client, token] in
            client?.appendText(text, for: token)
        }
    }

    func onThinking(text: String) {
        Task { @MainActor [client, token] in
            client?.appendThinking(text, for: token)
        }
    }

    func onDone(stopReason: String) {}

    func onError(message: String) {
        Task { @MainActor [client, token] in
            client?.publishStreamError(message, for: token)
        }
    }
}

/// Login-flow callbacks arrive on Rust worker threads; hop to the main actor.
/// Same `@unchecked Sendable` justification as `StreamBridge`.
private final class AuthBridge: CodexAuthDelegate, @unchecked Sendable {
    weak var client: EngineClient?
    let generation: UInt64

    init(client: EngineClient, generation: UInt64) {
        self.client = client
        self.generation = generation
    }

    func onAuthUrl(url: String) {
        Task { @MainActor [client, generation] in
            client?.publishAuthURL(url, generation: generation)
        }
    }
}
