import XCTest
@testable import CovenPocket

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

    func testPairingCheckPreventsOverlappingSessionLaunches() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)

        let firstSend = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.gateRequested], timeout: 1)

        let secondSend = Task {
            await model.send(prompt: "second", projectRoot: "/srv/repo")
        }
        await Task.yield()
        client.resumeGate()
        await firstSend.value
        await secondSend.value

        XCTAssertEqual(client.launchedPrompts, ["first"])
    }

    func testChangingProjectRootKillsAndLaunchesAFreshSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/one")
        model.apply(events: [
            RemoteEvent(
                seq: 1,
                kind: "result",
                payloadJson: #"{"type":"result","is_error":false}"#,
                createdAt: "t"
            )
        ])

        await model.send(prompt: "second", projectRoot: "/srv/two")

        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
        XCTAssertEqual(client.sentInputs, [])
    }

    func testResetInvalidatesSendSuspendedInPairing() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)
        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.gateRequested], timeout: 1)

        await model.reset()
        client.resumeGate()
        await send.value

        XCTAssertEqual(model.availability, .idle)
        XCTAssertTrue(client.launchedPrompts.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    func testResetKillsSessionReturnedBySuspendedLaunch() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)
        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)

        await model.reset()
        client.resumeLaunch()
        await send.value

        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    func testStopKillsSessionReturnedBySuspendedLaunch() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)
        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)

        await model.stop()
        client.resumeLaunch()
        await send.value

        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertFalse(model.isBusy)
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

}

@MainActor
final class CompanionChatHardeningStreamTests: XCTestCase {
    func testDaemonOutputChunksDecodeStreamJSONAndCompleteTurn() async throws {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventBatches = [
            RemoteEventBatch(
                events: [
                    try daemonOutputEvent(
                        seq: 7,
                        data: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Do"#
                    ),
                    try daemonOutputEvent(
                        seq: 8,
                        data: #"ne"}]}}"# + "\n"
                            + #"{"type":"result","subtype":"success","is_error":false}"# + "\n"
                    )
                ],
                nextAfterSeq: 8,
                hasMore: false
            )
        ]
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await model.refreshOnce()

        XCTAssertEqual(model.items.map(\.text), ["first", "Done", "Turn complete"])
        XCTAssertFalse(model.isBusy)
    }

    func testReapplyingSameEventsPreservesChatItemIdentities() throws {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        let events = [
            try daemonOutputEvent(
                seq: 1,
                data: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}"#
                    + "\n"
                    + #"{"type":"result","is_error":false}"# + "\n"
            )
        ]

        model.apply(events: events)
        let firstIDs = model.items.map(\.id)
        model.apply(events: events)

        XCTAssertEqual(model.items.map(\.id), firstIDs)
        XCTAssertEqual(Set(firstIDs).count, firstIDs.count)
    }

    func testDeadStreamRetryLaunchesAFreshSession() async {
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

        client.sendInputError = .sessionNotLive
        await model.send(prompt: "second", projectRoot: "/srv/repo")
        XCTAssertTrue(model.canRetry)

        client.sendInputError = nil
        await model.retry()

        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
        XCTAssertEqual(client.sentInputs, ["second"])
    }

    func testDaemonStreamExitSurfacesStderrAndAllowsFreshLaunch() async throws {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventBatches = [
            RemoteEventBatch(
                events: [
                    try daemonOutputEvent(
                        seq: 7,
                        data: #"{"type":"system","subtype":"stderr","text":"claude is not signed in"}"#
                            + "\n"
                    ),
                    RemoteEvent(
                        seq: 8,
                        kind: "exit",
                        payloadJson: #"{"status":"failed","exitCode":1}"#,
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

        XCTAssertTrue(model.items.map(\.text).contains("claude is not signed in"))
        XCTAssertTrue(model.items.map(\.text).contains("Session failed"))
        XCTAssertFalse(model.isBusy)

        await model.send(prompt: "second", projectRoot: "/srv/repo")
        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
    }

    func testCanonicalDaemonRootDoesNotRestartFollowUp() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.launchedProjectRoot = "/srv/repo"
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo/")
        model.apply(events: [
            RemoteEvent(
                seq: 1,
                kind: "result",
                payloadJson: #"{"type":"result","is_error":false}"#,
                createdAt: "t"
            )
        ])

        await model.send(prompt: "second", projectRoot: "/srv/repo/")

        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertEqual(client.sentInputs, ["second"])
    }

    func testDaemonRestartLaunchesAFreshSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/one")
        model.apply(events: [
            RemoteEvent(
                seq: 1,
                kind: "result",
                payloadJson: #"{"type":"result","is_error":false}"#,
                createdAt: "t"
            )
        ])
        client.gate = .ready(pairedDaemon(pid: 43, startedAt: "later"))

        await model.send(prompt: "second", projectRoot: "/srv/one")

        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
        XCTAssertTrue(client.sentInputs.isEmpty)
    }

    func testSessionNotFoundRetryLaunchesAFreshSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/one")
        model.apply(events: [
            RemoteEvent(
                seq: 1,
                kind: "result",
                payloadJson: #"{"type":"result","is_error":false}"#,
                createdAt: "t"
            )
        ])
        client.sendInputError = .sessionNotFound

        await model.send(prompt: "second", projectRoot: "/srv/one")
        client.sendInputError = nil
        await model.retry()

        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
    }

    func testRePairRetainsOldSessionForCleanup() async {
        let originalPairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(originalPairing))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/one")
        model.apply(events: [
            RemoteEvent(
                seq: 1,
                kind: "result",
                payloadJson: #"{"type":"result","is_error":false}"#,
                createdAt: "t"
            )
        ])
        client.gate = .ready(pairedDaemon(host: "other.tailnet.ts.net"))

        await model.send(prompt: "second", projectRoot: "/srv/one")

        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertTrue(client.sentInputs.isEmpty)
    }

    func testInterleavedStderrDoesNotCorruptPartialStreamFrame() async throws {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventBatches = [
            RemoteEventBatch(
                events: [
                    try daemonOutputEvent(
                        seq: 7,
                        data: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Do"#
                    ),
                    try daemonOutputEvent(
                        seq: 8,
                        data: #"{"type":"system","subtype":"stderr","text":"warning"}"# + "\n"
                    ),
                    try daemonOutputEvent(
                        seq: 9,
                        data: #"ne"}]}}"# + "\n"
                            + #"{"type":"result","subtype":"success","is_error":false}"# + "\n"
                    )
                ],
                nextAfterSeq: 9,
                hasMore: false
            )
        ]
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await model.refreshOnce()

        XCTAssertEqual(
            model.items.map(\.text),
            ["first", "warning", "Done", "Turn complete"]
        )
        XCTAssertFalse(model.isBusy)
    }

}
