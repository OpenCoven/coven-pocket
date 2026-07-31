import Foundation

@MainActor
final class SessionListModel: ObservableObject {
    typealias Loader = @MainActor () async throws -> [ChatSessionSummary]
    typealias Reindex = @MainActor ([ChatSessionSummary]) -> Void
    typealias DeleteSession = @MainActor (ChatSessionSummary) async throws -> Void
    typealias ForkSession = @MainActor (ChatSessionSummary) async throws -> Void

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    enum ErrorState: Hashable {
        case load
        case delete
        case fork

        var message: String {
            switch self {
            case .load: "Unable to load sessions"
            case .delete: "Unable to delete session"
            case .fork: "Unable to fork session"
            }
        }

        var allowsRetry: Bool {
            self == .load
        }
    }

    @Published private(set) var summaries: [ChatSessionSummary] = []
    @Published private(set) var loadState = LoadState.idle
    @Published private(set) var loadError: ErrorState?
    @Published private(set) var operationError: ErrorState?
    @Published private(set) var isMutating = false

    var error: ErrorState? {
        operationError ?? loadError
    }

    var errors: [ErrorState] {
        [loadError, operationError].compactMap { $0 }
    }

    private let loader: Loader
    private let reindex: Reindex
    private let deleteSession: DeleteSession?
    private let forkSession: ForkSession?
    private var refreshGeneration: UInt64 = 0
    private var settledLoadState = LoadState.idle
    private var operationErrorGeneration: UInt64 = 0
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        loader: @escaping Loader,
        reindex: @escaping Reindex,
        deleteSession: DeleteSession? = nil,
        forkSession: ForkSession? = nil
    ) {
        self.loader = loader
        self.reindex = reindex
        self.deleteSession = deleteSession
        self.forkSession = forkSession
    }

    convenience init() {
        let engine = PocketEngine()
        self.init(
            loader: {
                try await engine.listChatSessions(
                    storageDir: ChatModel.sessionStoreURL.path
                )
            },
            reindex: SessionSpotlight.reindex,
            deleteSession: { summary in
                try await engine.deleteChatSession(
                    storageDir: ChatModel.sessionStoreURL.path,
                    sessionId: summary.sessionId
                )
            },
            forkSession: { summary in
                _ = try await engine.forkChatSession(
                    storageDir: ChatModel.sessionStoreURL.path,
                    sessionId: summary.sessionId
                )
            }
        )
    }

    convenience init(chatModel: ChatModel) {
        self.init(
            loader: { try await chatModel.storedSessions() },
            reindex: SessionSpotlight.reindex,
            deleteSession: { try await chatModel.deleteSession($0) },
            forkSession: { try await chatModel.forkSession($0) }
        )
    }

    @discardableResult
    func refresh() async -> Bool {
        let cancellationState = settledLoadState
        let startingOperationErrorGeneration = operationErrorGeneration
        refreshGeneration &+= 1
        let generation = refreshGeneration
        loadState = .loading

        do {
            let loaded = try await loader()
            guard generation == refreshGeneration else { return false }
            guard !Task.isCancelled else {
                loadState = cancellationState
                return false
            }
            summaries = loaded
            loadState = .loaded
            settledLoadState = .loaded
            loadError = nil
            if operationErrorGeneration == startingOperationErrorGeneration {
                operationError = nil
            }
            reindex(loaded)
            return true
        } catch {
            guard generation == refreshGeneration else { return false }
            guard !Task.isCancelled else {
                loadState = cancellationState
                return false
            }
            loadState = .failed
            settledLoadState = .failed
            loadError = .load
            return false
        }
    }

    func delete(_ summary: ChatSessionSummary) async {
        await delete([summary])
    }

    func delete(_ targets: [ChatSessionSummary]) async {
        guard !targets.isEmpty else { return }
        await acquireMutation()
        defer { releaseMutation() }
        guard let deleteSession else {
            publishOperationError(.delete)
            return
        }

        var deleteFailed = false
        for summary in targets {
            do {
                try await deleteSession(summary)
            } catch {
                deleteFailed = true
            }
        }

        await refresh()
        if deleteFailed {
            publishOperationError(.delete)
        }
    }

    func fork(_ summary: ChatSessionSummary) async {
        await acquireMutation()
        defer { releaseMutation() }
        guard let forkSession else {
            publishOperationError(.fork)
            return
        }
        do {
            try await forkSession(summary)
            await refresh()
        } catch {
            guard !Task.isCancelled else { return }
            publishOperationError(.fork)
        }
    }

    private func publishOperationError(_ error: ErrorState) {
        operationErrorGeneration &+= 1
        operationError = error
    }

    private func acquireMutation() async {
        guard isMutating else {
            isMutating = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutation() {
        guard !mutationWaiters.isEmpty else {
            isMutating = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }
}

typealias ModalSessionsModel = SessionListModel
typealias SidebarSessionsModel = SessionListModel
