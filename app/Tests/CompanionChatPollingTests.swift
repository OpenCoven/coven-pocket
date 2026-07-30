import XCTest
@testable import CovenPocket

@MainActor
final class CompanionChatPollingTests: XCTestCase {
    func testPollingFailureCanRetryFromTheSameCursor() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventError = .polling
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await model.refreshOnce()

        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.cursor, 0)

        client.eventError = nil
        client.eventBatches = [
            RemoteEventBatch(
                events: [
                    RemoteEvent(
                        seq: 3,
                        kind: "assistant",
                        payloadJson: #"{"type":"assistant","message":{"content":"#
                            + #"[{"type":"text","text":"Recovered"}]}}"#,
                        createdAt: "t"
                    ),
                    RemoteEvent(
                        seq: 4,
                        kind: "result",
                        payloadJson: #"{"type":"result","is_error":false}"#,
                        createdAt: "t"
                    )
                ],
                nextAfterSeq: 4,
                hasMore: false
            )
        ]

        await model.retry()

        XCTAssertEqual(model.cursor, 4)
        XCTAssertEqual(model.items.map(\.text), ["first", "Recovered", "Turn complete"])
        XCTAssertFalse(model.canRetry)
    }

    func testPollingRetryPreventsOverlappingRetries() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventError = .polling
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await model.refreshOnce()
        client.eventError = nil
        client.suspendsGate = true
        let callsBeforeRetry = client.gateCallCount

        let firstRetry = Task { await model.retry() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        let secondRetry = Task { await model.retry() }
        await Task.yield()
        client.resumeGate()
        await firstRetry.value
        await secondRetry.value

        XCTAssertEqual(client.gateCallCount - callsBeforeRetry, 1)
    }

    func testPollingRetryAfterDaemonRestartDoesNotRebindStaleSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventError = .polling
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await model.refreshOnce()
        client.eventError = nil
        client.gate = .ready(pairedDaemon(pid: 43, startedAt: "later"))

        await model.retry()
        await model.send(prompt: "second", projectRoot: "/srv/repo")

        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
        XCTAssertTrue(client.sentInputs.isEmpty)
    }

    func testPollingRetryDoesNotRestartPollingAfterExit() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventError = .polling
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await model.refreshOnce()
        client.eventError = nil
        client.eventBatches = [
            RemoteEventBatch(
                events: [
                    RemoteEvent(
                        seq: 2,
                        kind: "exit",
                        payloadJson: #"{"status":"completed"}"#,
                        createdAt: "t"
                    )
                ],
                nextAfterSeq: 2,
                hasMore: false
            )
        ]

        await model.retry()

        XCTAssertFalse(model.hasActivePollTask)
    }

    func testIdlePollingFailureDoesNotOfferRetry() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        model.apply(events: [
            RemoteEvent(
                seq: 1,
                kind: "result",
                payloadJson: #"{"type":"result","is_error":false}"#,
                createdAt: "t"
            )
        ])
        client.eventError = .polling

        await model.refreshOnce()

        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRetry)
    }

    func testRepeatedPromptKeepsBothUserTurns() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventBatches = [
            RemoteEventBatch(
                events: [
                    RemoteEvent(
                        seq: 2,
                        kind: "input",
                        payloadJson: #"{"data":"repeat"}"#,
                        createdAt: "t"
                    ),
                    RemoteEvent(
                        seq: 3,
                        kind: "result",
                        payloadJson: #"{"type":"result","is_error":false}"#,
                        createdAt: "t"
                    )
                ],
                nextAfterSeq: 3,
                hasMore: false
            )
        ]
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "repeat", projectRoot: "/srv/repo")
        await model.refreshOnce()

        XCTAssertEqual(model.items.map(\.text), ["repeat", "repeat", "Turn complete"])
        await model.reset()
    }

    func testResetKillsTheActiveDaemonSessionAndClearsState() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        await model.reset()

        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertNil(model.sessionFamiliarID)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.cursor, 0)
        XCTAssertFalse(model.isBusy)
    }

    func testResetIgnoresEventsReturnedByCanceledPoll() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsEvents = true
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await fulfillment(of: [client.eventsRequested], timeout: 1)

        await model.reset()
        client.resumeEvents(
            with: RemoteEventBatch(
                events: [
                    RemoteEvent(
                        seq: 1,
                        kind: "assistant",
                        payloadJson: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Late"}]}}"#,
                        createdAt: "t"
                    )
                ],
                nextAfterSeq: 1,
                hasMore: false
            )
        )
        await Task.yield()

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.cursor, 0)
        XCTAssertFalse(model.isBusy)
    }

    func testNewSendIgnoresEventsReturnedByPreviousPoll() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsEvents = true
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await fulfillment(of: [client.eventsRequested], timeout: 1)
        model.apply(events: [
            RemoteEvent(
                seq: 1,
                kind: "result",
                payloadJson: #"{"type":"result","is_error":false}"#,
                createdAt: "t"
            )
        ])

        client.suspendsEvents = false
        await model.send(prompt: "second", projectRoot: "/srv/repo")
        client.resumeEvents(
            with: RemoteEventBatch(
                events: [
                    RemoteEvent(
                        seq: 2,
                        kind: "exit",
                        payloadJson: #"{"status":"completed"}"#,
                        createdAt: "t"
                    )
                ],
                nextAfterSeq: 2,
                hasMore: false
            )
        )
        await Task.yield()

        XCTAssertTrue(model.isBusy)
    }
}
