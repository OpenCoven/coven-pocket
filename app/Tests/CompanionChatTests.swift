import XCTest
@testable import CovenPocket

enum FakeCompanionError: LocalizedError {
    case polling
    case sessionNotLive

    var errorDescription: String? {
        switch self {
        case .polling:
            return "Polling failed"
        case .sessionNotLive:
            return "engine error: Session is not running."
        }
    }
}

@MainActor
final class FakeCompanionSessionClient: CompanionSessionClient {
    var gate: CompanionModel.SessionGate
    var launchedPrompts: [String] = []
    var sentInputs: [String] = []
    var killedSessionIDs: [String] = []
    var eventBatches: [RemoteEventBatch] = []
    var eventError: FakeCompanionError?
    var sendInputError: FakeCompanionError?
    var killError: FakeCompanionError?
    var suspendsEvents = false
    let eventsRequested = XCTestExpectation(description: "events requested")
    private var eventsContinuation: CheckedContinuation<RemoteEventBatch, Never>?

    init(gate: CompanionModel.SessionGate) {
        self.gate = gate
    }

    func sessionGate() async -> CompanionModel.SessionGate { gate }

    func launch(
        pairing: DaemonPairing,
        projectRoot: String,
        prompt: String,
        title: String
    ) async throws -> RemoteSession {
        launchedPrompts.append(prompt)
        return RemoteSession(
            id: "session-1",
            harness: "claude",
            title: title,
            status: "running",
            projectRoot: projectRoot,
            createdAt: "c",
            updatedAt: "u"
        )
    }

    func events(
        pairing: DaemonPairing,
        sessionID: String,
        afterSeq: Int64
    ) async throws -> RemoteEventBatch {
        if suspendsEvents {
            eventsRequested.fulfill()
            return await withCheckedContinuation { continuation in
                eventsContinuation = continuation
            }
        }
        if let eventError {
            throw eventError
        }
        if eventBatches.isEmpty {
            return RemoteEventBatch(
                events: [],
                nextAfterSeq: afterSeq,
                hasMore: false
            )
        }
        return eventBatches.removeFirst()
    }

    func sendInput(
        pairing: DaemonPairing,
        sessionID: String,
        data: String
    ) async throws {
        if let sendInputError {
            throw sendInputError
        }
        sentInputs.append(data)
    }

    func kill(pairing: DaemonPairing, sessionID: String) async throws {
        if let killError {
            throw killError
        }
        killedSessionIDs.append(sessionID)
    }

    func resumeEvents(with batch: RemoteEventBatch) {
        let continuation = eventsContinuation
        eventsContinuation = nil
        continuation?.resume(returning: batch)
    }
}

func pairedDaemon() -> DaemonPairing {
    DaemonPairing(
        host: "mac.tailnet.ts.net",
        port: 7777,
        apiVersion: "coven.daemon.v1",
        covenVersion: "0.7.0",
        pid: 42,
        startedAt: "now",
        pairedAt: Date()
    )
}

func daemonOutputEvent(seq: Int64, data: String) throws -> RemoteEvent {
    let payload = try JSONSerialization.data(withJSONObject: ["data": data])
    guard let payloadJSON = String(data: payload, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return RemoteEvent(
        seq: seq,
        kind: "output",
        payloadJson: payloadJSON,
        createdAt: "t"
    )
}

@MainActor
final class CompanionChatTests: XCTestCase {
    func testFirstTurnLaunchesOnceAndFollowUpUsesInput() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "first", projectRoot: " /srv/repo ")
        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertEqual(client.sentInputs, [])
        XCTAssertEqual(model.items.map(\.text), ["first"])

        model.apply(events: [
            RemoteEvent(
                seq: 1,
                kind: "result",
                payloadJson: #"{"type":"result","is_error":false}"#,
                createdAt: "t"
            )
        ])
        await model.send(prompt: "second", projectRoot: "/srv/repo")

        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertEqual(client.sentInputs, ["second"])
    }

    func testUnverifiedPairingBlocksWithoutLaunching() async {
        let client = FakeCompanionSessionClient(gate: .notPaired)
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "hello", projectRoot: "/srv/repo")

        XCTAssertTrue(client.launchedPrompts.isEmpty)
        XCTAssertTrue(client.sentInputs.isEmpty)
        XCTAssertFalse(model.items.isEmpty)
    }

    func testEventsAdvanceCursorAndRenderTurnCompletion() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventBatches = [
            RemoteEventBatch(
                events: [
                    RemoteEvent(
                        seq: 7,
                        kind: "assistant",
                        payloadJson: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}"#,
                        createdAt: "t"
                    ),
                    RemoteEvent(
                        seq: 8,
                        kind: "result",
                        payloadJson: #"{"type":"result","is_error":false}"#,
                        createdAt: "t"
                    )
                ],
                nextAfterSeq: 8,
                hasMore: false
            )
        ]
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await model.refreshOnce()

        XCTAssertEqual(model.cursor, 8)
        XCTAssertEqual(model.items.map(\.text), ["first", "Done", "Turn complete"])
        XCTAssertFalse(model.isBusy)
    }

    func testSendAfterStopLaunchesWithAFreshEventCursor() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        model.apply(events: [
            RemoteEvent(
                seq: 8,
                kind: "result",
                payloadJson: #"{"type":"result","is_error":false}"#,
                createdAt: "t"
            )
        ])

        await model.stop()
        await model.send(prompt: "second", projectRoot: "/srv/repo")

        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
        XCTAssertEqual(model.cursor, 0)
    }

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
        await model.send(prompt: "first", projectRoot: "/srv/repo")

        await model.reset()

        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
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
}
