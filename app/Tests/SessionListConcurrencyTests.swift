import XCTest
@testable import CovenPocket

@MainActor
final class SessionListConcurrencyTests: XCTestCase {
    private enum Failure: Error {
        case list
    }

    func testCancelledNewerRefreshRestoresLastSettledState() async {
        let prior = summary(id: "prior")
        let olderStarted = expectation(description: "older refresh started")
        let newerStarted = expectation(description: "newer refresh started")
        var requestCount = 0
        var olderContinuation: CheckedContinuation<[ChatSessionSummary], Error>?
        var newerContinuation: CheckedContinuation<[ChatSessionSummary], Error>?
        var reindexed: [[ChatSessionSummary]] = []
        let model = SessionListModel(
            loader: {
                requestCount += 1
                switch requestCount {
                case 1:
                    return [prior]
                case 2:
                    return try await withCheckedThrowingContinuation { continuation in
                        olderContinuation = continuation
                        olderStarted.fulfill()
                    }
                default:
                    return try await withCheckedThrowingContinuation { continuation in
                        newerContinuation = continuation
                        newerStarted.fulfill()
                    }
                }
            },
            reindex: { reindexed.append($0) }
        )
        await model.refresh()
        reindexed.removeAll()

        let older = Task { await model.refresh() }
        await fulfillment(of: [olderStarted], timeout: 1)
        let newer = Task { await model.refresh() }
        await fulfillment(of: [newerStarted], timeout: 1)
        newer.cancel()
        newerContinuation?.resume(returning: [summary(id: "cancelled")])
        _ = await newer.value
        olderContinuation?.resume(throwing: Failure.list)
        _ = await older.value

        XCTAssertEqual(model.summaries, [prior])
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertNil(model.error)
        XCTAssertTrue(reindexed.isEmpty)
    }

    func testMutationFailureDoesNotBlockAuthoritativeRefresh() async {
        let prior = summary(id: "prior")
        let refreshStarted = expectation(description: "refresh started")
        var requestCount = 0
        var continuation: CheckedContinuation<[ChatSessionSummary], Error>?
        var reindexed: [[ChatSessionSummary]] = []
        let model = SessionListModel(
            loader: {
                requestCount += 1
                if requestCount == 1 {
                    return [prior]
                }
                return try await withCheckedThrowingContinuation { pending in
                    continuation = pending
                    refreshStarted.fulfill()
                }
            },
            reindex: { reindexed.append($0) },
            forkSession: { _ in throw Failure.list }
        )
        await model.refresh()
        reindexed.removeAll()

        let refresh = Task { await model.refresh() }
        await fulfillment(of: [refreshStarted], timeout: 1)
        await model.fork(prior)
        let refreshed = summary(id: "refreshed")
        continuation?.resume(returning: [refreshed])
        _ = await refresh.value

        XCTAssertEqual(model.summaries, [refreshed])
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.error, .fork)
        XCTAssertEqual(reindexed, [[refreshed]])
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
