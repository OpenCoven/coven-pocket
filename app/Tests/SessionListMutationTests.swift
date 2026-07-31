import XCTest
@testable import CovenPocket

@MainActor
final class SessionListMutationTests: XCTestCase {
    private enum Failure: Error {
        case delete
    }

    func testPartialBatchDeleteReloadsSuccessesAndRetainsDeleteError() async {
        let first = summary(id: "first")
        let second = summary(id: "second")
        var stored = [first, second]
        var reindexed: [[ChatSessionSummary]] = []
        let model = SessionListModel(
            loader: { stored },
            reindex: { reindexed.append($0) },
            deleteSession: { summary in
                if summary.sessionId == second.sessionId {
                    throw Failure.delete
                }
                stored.removeAll { $0.sessionId == summary.sessionId }
            }
        )
        await model.refresh()
        reindexed.removeAll()

        await model.delete([first, second])

        XCTAssertEqual(model.summaries, [second])
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.error, .delete)
        XCTAssertEqual(reindexed, [[second]])
    }

    func testPartialBatchDeleteSurfacesDeleteAndReloadFailures() async {
        let first = summary(id: "first")
        let second = summary(id: "second")
        var loadCount = 0
        var stored = [first, second]
        var reindexCount = 0
        let model = SessionListModel(
            loader: {
                loadCount += 1
                if loadCount == 1 {
                    return stored
                }
                throw Failure.delete
            },
            reindex: { _ in reindexCount += 1 },
            deleteSession: { summary in
                if summary.sessionId == second.sessionId {
                    throw Failure.delete
                }
                stored.removeAll { $0.sessionId == summary.sessionId }
            }
        )
        await model.refresh()

        await model.delete([first, second])

        XCTAssertEqual(model.summaries, [first, second])
        XCTAssertEqual(model.loadState, .failed)
        XCTAssertEqual(model.loadError, .load)
        XCTAssertEqual(model.operationError, .delete)
        XCTAssertEqual(reindexCount, 1)
    }

    func testDeleteErrorReconcilesEngineSideEffectsBeforePublishingError() async {
        let existing = summary(id: "existing")
        var stored = [existing]
        var reindexed: [[ChatSessionSummary]] = []
        let model = SessionListModel(
            loader: { stored },
            reindex: { reindexed.append($0) },
            deleteSession: { _ in
                stored = []
                throw Failure.delete
            }
        )
        await model.refresh()
        reindexed.removeAll()

        await model.delete(existing)

        XCTAssertTrue(model.summaries.isEmpty)
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.operationError, .delete)
        XCTAssertEqual(model.errors, [.delete])
        XCTAssertEqual(reindexed, [[]])
    }

    func testDeleteUsesCapturedIdentityAfterListReorders() async {
        let first = summary(id: "first")
        let second = summary(id: "second")
        var stored = [first, second]
        var deletedIDs: [String] = []
        let model = SessionListModel(
            loader: { stored },
            reindex: { _ in },
            deleteSession: { summary in
                deletedIDs.append(summary.sessionId)
                stored.removeAll { $0.sessionId == summary.sessionId }
            }
        )
        await model.refresh()
        let captured = [model.summaries[1]]
        stored = [second, first]
        await model.refresh()

        await model.delete(captured)

        XCTAssertEqual(deletedIDs, [second.sessionId])
        XCTAssertEqual(model.summaries, [first])
    }

    func testMutationsSerializeSoOlderWorkCannotEraseNewerError() async {
        let existing = summary(id: "existing")
        let deleteStarted = expectation(description: "delete started")
        var deleteContinuation: CheckedContinuation<Void, Never>?
        var stored = [existing]
        var forkCallCount = 0
        let model = SessionListModel(
            loader: { stored },
            reindex: { _ in },
            deleteSession: { _ in
                deleteStarted.fulfill()
                await withCheckedContinuation { continuation in
                    deleteContinuation = continuation
                }
                stored = []
            },
            forkSession: { _ in
                forkCallCount += 1
                throw Failure.delete
            }
        )
        await model.refresh()

        let delete = Task { await model.delete(existing) }
        await fulfillment(of: [deleteStarted], timeout: 1)
        let fork = Task { await model.fork(existing) }
        await Task.yield()
        XCTAssertTrue(model.isMutating)
        XCTAssertEqual(forkCallCount, 0)

        deleteContinuation?.resume()
        await delete.value
        await fork.value

        XCTAssertFalse(model.isMutating)
        XCTAssertEqual(model.summaries, [])
        XCTAssertEqual(model.operationError, .fork)
    }

    private func summary(id: String) -> ChatSessionSummary {
        ChatSessionSummary(
            sessionId: id,
            title: id,
            model: "claude-test",
            createdAt: "2026-07-30T00:00:00Z",
            updatedAt: "2026-07-30T00:00:00Z",
            messageCount: 1,
            familiar: nil
        )
    }
}
