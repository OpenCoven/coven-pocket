import Foundation
@testable import CovenPocket

enum EngineClientTestError: LocalizedError {
    case staleStream
    case staleModelLoad
    case logoutCleanup

    var errorDescription: String? {
        switch self {
        case .staleStream:
            "stale stream failed"
        case .staleModelLoad:
            "stale model load failed"
        case .logoutCleanup:
            "logout cleanup failed"
        }
    }
}

final class ControllableEngineClientEngine: EngineClientEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var account: CodexAccount?
    private var immediateStreamCount = 0
    private var streamDelegates: [CovenPocket.StreamDelegate] = []
    private var streamContinuations: [
        Int: CheckedContinuation<Void, Error>
    ] = [:]
    private var authDelegates: [CodexAuthDelegate] = []
    private var authContinuations: [
        Int: CheckedContinuation<CodexAccount, Error>
    ] = [:]
    private var logoutCallTotal = 0
    private var logoutFailureCount = 0
    private var suspendedCodexModelLoadCount = 0
    private var codexModelLoadCallTotal = 0
    private var codexModelContinuations: [
        Int: CheckedContinuation<[PocketModel], Error>
    ] = [:]

    init(account: CodexAccount? = nil) {
        self.account = account
    }

    var streamCallCount: Int {
        lock.withLock { streamDelegates.count }
    }

    var pendingStreamCount: Int {
        lock.withLock { streamContinuations.count }
    }

    var loginCallCount: Int {
        lock.withLock { authDelegates.count }
    }

    var pendingLoginCount: Int {
        lock.withLock { authContinuations.count }
    }

    var logoutCallCount: Int {
        lock.withLock { logoutCallTotal }
    }

    var codexModelLoadCallCount: Int {
        lock.withLock { codexModelLoadCallTotal }
    }

    var pendingCodexModelLoadCount: Int {
        lock.withLock { codexModelContinuations.count }
    }

    func engineVersion() -> String {
        "test"
    }

    func defaultModel() -> String {
        "anthropic-test"
    }

    func defaultCodexModel() -> String {
        "codex-test"
    }

    func codexAccount() -> CodexAccount? {
        lock.withLock { account }
    }

    func listModels(apiKey: String) async throws -> [PocketModel] {
        []
    }

    func listCodexModels() async throws -> [PocketModel] {
        let callIndex = lock.withLock {
            let index = codexModelLoadCallTotal
            codexModelLoadCallTotal += 1
            return index
        }
        let shouldSuspend = lock.withLock {
            guard suspendedCodexModelLoadCount > 0 else { return false }
            suspendedCodexModelLoadCount -= 1
            return true
        }
        guard shouldSuspend else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                codexModelContinuations[callIndex] = continuation
            }
        }
    }

    func codexLogin(
        delegate: CodexAuthDelegate
    ) async throws -> CodexAccount {
        let callIndex = lock.withLock {
            authDelegates.append(delegate)
            return authDelegates.count - 1
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                authContinuations[callIndex] = continuation
            }
        }
    }

    func codexLogout() throws {
        let shouldFail = lock.withLock {
            logoutCallTotal += 1
            guard logoutFailureCount > 0 else {
                account = nil
                return false
            }
            logoutFailureCount -= 1
            return true
        }
        if shouldFail {
            throw EngineClientTestError.logoutCleanup
        }
    }

    func failNextLogouts(_ count: Int) {
        lock.withLock {
            logoutFailureCount += count
        }
    }

    // swiftlint:disable:next function_parameter_count
    func streamPrompt(
        provider: PocketProvider,
        apiKey: String,
        model: String,
        prompt: String,
        effort: String?,
        delegate: CovenPocket.StreamDelegate
    ) async throws {
        let (callIndex, completesImmediately) = lock.withLock {
            let index = streamDelegates.count
            streamDelegates.append(delegate)
            guard immediateStreamCount > 0 else { return (index, false) }
            immediateStreamCount -= 1
            return (index, true)
        }
        guard !completesImmediately else { return }
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                streamContinuations[callIndex] = continuation
            }
        }
    }

    func completeNextStreamsImmediately(_ count: Int) {
        lock.withLock {
            immediateStreamCount += count
        }
    }

    func suspendNextCodexModelLoads(_ count: Int) {
        lock.withLock {
            suspendedCodexModelLoadCount += count
        }
    }

    func emitText(_ text: String, stream index: Int) {
        streamDelegate(at: index)?.onText(text: text)
    }

    func emitThinking(_ text: String, stream index: Int) {
        streamDelegate(at: index)?.onThinking(text: text)
    }

    func emitError(_ message: String, stream index: Int) {
        streamDelegate(at: index)?.onError(message: message)
    }

    func finishStream(
        at index: Int,
        with result: Result<Void, Error> = .success(())
    ) {
        let continuation = lock.withLock {
            streamContinuations.removeValue(forKey: index)
        }
        continuation?.resume(with: result)
    }

    func finishAllStreams() {
        let continuations = lock.withLock {
            let pending = Array(streamContinuations.values)
            streamContinuations.removeAll()
            return pending
        }
        continuations.forEach { $0.resume() }
    }

    func emitAuthURL(_ url: String, login index: Int) {
        let delegate = lock.withLock {
            authDelegates.indices.contains(index) ? authDelegates[index] : nil
        }
        delegate?.onAuthUrl(url: url)
    }

    func finishLogin(
        at index: Int,
        with result: Result<CodexAccount, Error>
    ) {
        let continuation = lock.withLock {
            if case let .success(newAccount) = result {
                account = newAccount
            }
            return authContinuations.removeValue(forKey: index)
        }
        continuation?.resume(with: result)
    }

    func finishCodexModelLoad(
        at index: Int,
        with result: Result<[PocketModel], Error>
    ) {
        let continuation = lock.withLock {
            codexModelContinuations.removeValue(forKey: index)
        }
        continuation?.resume(with: result)
    }

    private func streamDelegate(
        at index: Int
    ) -> CovenPocket.StreamDelegate? {
        lock.withLock {
            streamDelegates.indices.contains(index)
                ? streamDelegates[index]
                : nil
        }
    }
}
