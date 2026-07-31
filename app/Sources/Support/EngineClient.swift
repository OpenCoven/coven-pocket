import Foundation

struct StreamOperationToken: Equatable, Sendable {
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
            invalidateCodexAccountState()
        }
    }
    @Published var authURL: URL?
    @Published var isAuthenticating = false
    @Published private(set) var authenticationCleanupRequired = false
    @Published private(set) var authenticationCleanupError: String?

    let engine: any EngineClientEngine
    private let authenticationCleanupStore: any AuthenticationCleanupStore

    private var streamGeneration: UInt64 = 0
    private var currentStream: StreamOperationToken?
    private var activeStream: StreamOperationToken?
    private var authGeneration: UInt64 = 0
    private var activeAuthGeneration: UInt64?
    // Rust login owns a fixed callback port and outlives Swift cancellation.
    private var isAuthenticationEngineInFlight = false
    private var pendingAuthenticationSlot: PendingAuthenticationSlot?
    private var modelLoadGeneration: UInt64 = 0
    private var codexModelLoadGeneration: UInt64 = 0

    var engineVersion: String { engine.engineVersion() }
    var defaultModel: String { engine.defaultModel() }
    var defaultCodexModel: String { engine.defaultCodexModel() }

    init(
        engine: any EngineClientEngine = PocketEngine(),
        authenticationCleanupStore: any AuthenticationCleanupStore =
            UserDefaultsAuthenticationCleanupStore()
    ) {
        self.engine = engine
        self.authenticationCleanupStore = authenticationCleanupStore
        authenticationCleanupRequired =
            authenticationCleanupStore.cleanupRequired
        if authenticationCleanupRequired {
            attemptAuthenticationCleanup()
        } else {
            codexAccount = engine.codexAccount()
        }
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
            attemptAuthenticationCleanup()
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
        let authenticationWasInFlight = isAuthenticationEngineInFlight
        invalidateAuthentication()
        retainAuthenticationCleanup(
            error: authenticationWasInFlight
                ? """
                Codex sign-out cleanup is waiting for the active sign-in to \
                finish. Choose Finish sign out to retry afterward.
                """
                : nil
        )
        guard !authenticationWasInFlight else { return }
        attemptAuthenticationCleanup()
    }

    func retryAuthenticationCleanup() {
        guard authenticationCleanupRequired else { return }
        guard activeAuthGeneration == nil,
              !isAuthenticationEngineInFlight
        else {
            return
        }
        invalidateAuthentication()
        attemptAuthenticationCleanup()
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
    func appendText(
        _ text: String,
        for token: StreamOperationToken
    ) {
        guard isCurrentStream(token) else { return }
        transcript += text
    }

    func appendThinking(
        _ text: String,
        for token: StreamOperationToken
    ) {
        guard isCurrentStream(token) else { return }
        thinking += text
    }

    func publishStreamError(
        _ message: String,
        for token: StreamOperationToken
    ) {
        guard isCurrentStream(token) else { return }
        errorMessage = message
    }

    func publishAuthURL(
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

    private func invalidateCodexAccountState() {
        codexModels = []
        codexModelLoadGeneration &+= 1
        invalidateCurrentCodexStream()
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
        guard authenticationCleanupRequired else { return true }
        guard isCurrentAuthentication(generation) else { return false }
        return attemptAuthenticationCleanup()
    }

    private func attemptAuthenticationCleanup() -> Bool {
        retainAuthenticationCleanup(error: nil)
        do {
            try engine.codexLogout()
        } catch {
            authenticationCleanupError = """
            Codex sign-out cleanup failed: \(error.localizedDescription). \
            Choose Finish sign out to retry.
            """
            return false
        }
        authenticationCleanupStore.cleanupRequired = false
        authenticationCleanupRequired = false
        authenticationCleanupError = nil
        clearAuthenticationPresentation()
        return true
    }

    private func retainAuthenticationCleanup(error: String?) {
        authenticationCleanupStore.cleanupRequired = true
        authenticationCleanupRequired = true
        clearAuthenticationPresentation()
        if let error {
            authenticationCleanupError = error
        }
    }

    private func clearAuthenticationPresentation() {
        authURL = nil
        if codexAccount == nil {
            invalidateCodexAccountState()
        } else {
            codexAccount = nil
        }
    }
}
