import XCTest
@testable import CovenPocket

@MainActor
final class SessionListTests: XCTestCase {
    private enum Failure: LocalizedError {
        case list
        case delete
        case fork

        var errorDescription: String? {
            switch self {
            case .list: "Malformed familiar metadata."
            case .delete: "Delete failed."
            case .fork: "Fork failed."
            }
        }
    }

    func testLoadFailureRetainsPriorSummariesAndSkipsReindex() async {
        let prior = [summary(id: "prior")]
        var attempt = 0
        var reindexed: [[ChatSessionSummary]] = []
        let model = SessionListModel(
            loader: {
                attempt += 1
                if attempt == 1 {
                    return prior
                }
                throw Failure.list
            },
            reindex: { reindexed.append($0) }
        )

        await model.refresh()
        reindexed.removeAll()
        await model.refresh()

        XCTAssertEqual(model.summaries, prior)
        XCTAssertEqual(model.loadState, .failed)
        XCTAssertEqual(model.error, .load)
        XCTAssertTrue(reindexed.isEmpty)
    }

    func testInitialLoadFailureIsUnavailableRatherThanSuccessfulEmpty() async {
        let model = SessionListModel(
            loader: { throw Failure.list },
            reindex: { _ in XCTFail("failed loads must not reindex") }
        )

        await model.refresh()

        XCTAssertTrue(model.summaries.isEmpty)
        XCTAssertEqual(model.loadState, .failed)
        XCTAssertEqual(model.error?.message, "Unable to load sessions")
        XCTAssertNotEqual(model.loadState, .loaded)
    }

    func testLaterSuccessReplacesSummariesClearsErrorAndReindexesOnce() async {
        let loaded = [summary(id: "loaded")]
        var attempt = 0
        var reindexed: [[ChatSessionSummary]] = []
        let model = SessionListModel(
            loader: {
                attempt += 1
                if attempt == 1 {
                    throw Failure.list
                }
                return loaded
            },
            reindex: { reindexed.append($0) }
        )

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(model.summaries, loaded)
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertNil(model.error)
        XCTAssertEqual(reindexed, [loaded])
    }

    func testSuccessfulEmptyLoadClearsAndReindexesEmptyOnce() async {
        let prior = [summary(id: "prior")]
        var attempt = 0
        var reindexed: [[ChatSessionSummary]] = []
        let model = SessionListModel(
            loader: {
                attempt += 1
                return attempt == 1 ? prior : []
            },
            reindex: { reindexed.append($0) }
        )

        await model.refresh()
        reindexed.removeAll()
        await model.refresh()

        XCTAssertTrue(model.summaries.isEmpty)
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertNil(model.error)
        XCTAssertEqual(reindexed.count, 1)
        XCTAssertEqual(reindexed[0], [])
    }

    func testOlderFailureCannotOverwriteNewerSuccess() async {
        let newerSummary = summary(id: "newer")
        let olderStarted = expectation(description: "older load started")
        let newerStarted = expectation(description: "newer load started")
        var requestCount = 0
        var olderContinuation: CheckedContinuation<[ChatSessionSummary], Error>?
        var newerContinuation: CheckedContinuation<[ChatSessionSummary], Error>?
        var reindexed: [[ChatSessionSummary]] = []
        let model = SessionListModel(
            loader: {
                requestCount += 1
                let request = requestCount
                return try await withCheckedThrowingContinuation { continuation in
                    if request == 1 {
                        olderContinuation = continuation
                        olderStarted.fulfill()
                    } else {
                        newerContinuation = continuation
                        newerStarted.fulfill()
                    }
                }
            },
            reindex: { reindexed.append($0) }
        )

        let older = Task { await model.refresh() }
        await fulfillment(of: [olderStarted], timeout: 1)
        let newer = Task { await model.refresh() }
        await fulfillment(of: [newerStarted], timeout: 1)

        newerContinuation?.resume(returning: [newerSummary])
        _ = await newer.value
        olderContinuation?.resume(throwing: Failure.list)
        _ = await older.value

        XCTAssertEqual(model.summaries, [newerSummary])
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertNil(model.error)
        XCTAssertEqual(reindexed, [[newerSummary]])
    }

    func testModalAndSidebarModelsUseTheSameFailurePreservingState() async {
        let factories: [() -> SessionListModel] = [
            {
                ModalSessionsModel(
                    loader: { throw Failure.list },
                    reindex: { _ in XCTFail("modal failure must not reindex") }
                )
            },
            {
                SidebarSessionsModel(
                    loader: { throw Failure.list },
                    reindex: { _ in XCTFail("sidebar failure must not reindex") }
                )
            }
        ]

        for makeModel in factories {
            let model = makeModel()
            await model.refresh()
            XCTAssertEqual(model.loadState, .failed)
            XCTAssertEqual(model.error, .load)
            XCTAssertTrue(model.summaries.isEmpty)
        }
    }

    func testDeleteFailureReloadsWithoutOptimisticallyRemovingRows() async {
        let existing = summary(id: "existing")
        var loadCount = 0
        var reindexed: [[ChatSessionSummary]] = []
        let model = SessionListModel(
            loader: {
                loadCount += 1
                return [existing]
            },
            reindex: { reindexed.append($0) },
            deleteSession: { _ in throw Failure.delete }
        )

        await model.refresh()
        reindexed.removeAll()
        await model.delete(existing)

        XCTAssertEqual(model.summaries, [existing])
        XCTAssertEqual(model.error, .delete)
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(reindexed, [[existing]])
    }

    func testSuccessfulDeleteReloadsThroughRefreshPath() async {
        let existing = summary(id: "existing")
        var stored = [existing]
        var reindexed: [[ChatSessionSummary]] = []
        let model = SessionListModel(
            loader: { stored },
            reindex: { reindexed.append($0) },
            deleteSession: { summary in
                stored.removeAll { $0.sessionId == summary.sessionId }
            }
        )

        await model.refresh()
        reindexed.removeAll()
        await model.delete(existing)

        XCTAssertTrue(model.summaries.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertEqual(reindexed, [[]])
    }

    func testSuccessfulForkReloadsThroughRefreshPath() async {
        let existing = summary(id: "existing")
        let forked = summary(id: "forked")
        var stored = [existing]
        var reindexed: [[ChatSessionSummary]] = []
        let model = SessionListModel(
            loader: { stored },
            reindex: { reindexed.append($0) },
            forkSession: { _ in stored = [forked, existing] }
        )

        await model.refresh()
        reindexed.removeAll()
        await model.fork(existing)

        XCTAssertEqual(model.summaries, [forked, existing])
        XCTAssertNil(model.error)
        XCTAssertEqual(reindexed, [[forked, existing]])
    }

    func testChatModelStoredSessionsPropagatesLoaderFailure() async {
        let model = ChatModel(storedSessionsLoader: { throw Failure.list })

        do {
            _ = try await model.storedSessions()
            XCTFail("storedSessions must propagate the loader error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Malformed familiar metadata.")
        }
    }

    func testFailedSpotlightLookupRetiresRouteWithoutResuming() async {
        let model = ChatModel(storedSessionsLoader: { throw Failure.list })
        let coordinator = ChatRouteGenerationCoordinator()
        let token = coordinator.begin()
        var resumeCount = 0

        await SpotlightSessionRouteRunner.run(
            token: token,
            coordinator: coordinator,
            lookup: {
                await ChatView.spotlightSession(
                    sessionID: "missing",
                    loader: { try await model.storedSessions() }
                )
            },
            cancelResume: {},
            resume: { _ in resumeCount += 1 }
        )

        XCTAssertEqual(resumeCount, 0)
        XCTAssertFalse(coordinator.isCurrent(token))
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
