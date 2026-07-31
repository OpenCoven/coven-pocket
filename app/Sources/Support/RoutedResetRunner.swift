import Foundation

@MainActor
final class RoutedResetRunner {
    private struct ActiveReset {
        let token: UInt64
        let task: Task<Void, Never>
    }

    private var nextToken: UInt64 = 0
    private var activeReset: ActiveReset?

    func launch(
        _ reset: @escaping @MainActor () async -> Void
    ) {
        guard activeReset == nil else { return }
        nextToken &+= 1
        let token = nextToken
        let task = Task { @MainActor [weak self] in
            await reset()
            self?.finish(token: token)
        }
        activeReset = ActiveReset(token: token, task: task)
    }

    func waitForCompletion() async {
        while let task = activeReset?.task {
            await task.value
        }
    }

    private func finish(token: UInt64) {
        guard activeReset?.token == token else { return }
        activeReset = nil
    }
}
