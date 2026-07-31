import Foundation

@MainActor
final class RoutedResetRunner {
    private struct ResetRequest {
        let backend: ChatBackend
        let operation: @MainActor () async -> Void
    }

    private struct ActiveReset {
        let token: UInt64
        let backend: ChatBackend
        let task: Task<Void, Never>
    }

    private var nextToken: UInt64 = 0
    private var activeReset: ActiveReset?
    // ChatBackend has two identities, so one differing pending reset is enough.
    private var pendingReset: ResetRequest?

    func launch(
        for backend: ChatBackend,
        _ reset: @escaping @MainActor () async -> Void
    ) {
        guard activeReset?.backend != backend else { return }
        guard pendingReset?.backend != backend else { return }

        let request = ResetRequest(backend: backend, operation: reset)
        guard activeReset == nil else {
            pendingReset = request
            return
        }
        start(request)
    }

    func waitForCompletion() async {
        while let task = activeReset?.task {
            await task.value
        }
    }

    private func start(_ request: ResetRequest) {
        nextToken &+= 1
        let token = nextToken
        let task = Task { @MainActor in
            await request.operation()
            self.finish(token: token)
        }
        activeReset = ActiveReset(
            token: token,
            backend: request.backend,
            task: task
        )
    }

    private func finish(token: UInt64) {
        guard activeReset?.token == token else { return }
        activeReset = nil
        guard let pendingReset else { return }
        self.pendingReset = nil
        start(pendingReset)
    }
}
