import XCTest
@testable import CovenPocket

@MainActor
final class CompanionChatStreamTests: XCTestCase {
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

    func testCompleteFinalFrameDoesNotRequireTrailingNewline() async throws {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventBatches = [
            RemoteEventBatch(
                events: [
                    try daemonOutputEvent(
                        seq: 7,
                        data: #"{"type":"result","subtype":"success","is_error":false}"#
                    )
                ],
                nextAfterSeq: 7,
                hasMore: false
            )
        ]
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await model.refreshOnce()

        XCTAssertEqual(model.items.map(\.text), ["first", "Turn complete"])
        XCTAssertFalse(model.isBusy)
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
        XCTAssertEqual(client.sentInputs, [])
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

    func testStreamOutputRendersAsStatusWithoutSendingControlInput() async throws {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.eventBatches = [
            RemoteEventBatch(
                events: [
                    try daemonOutputEvent(
                        seq: 7,
                        data: #"{"type":"output","text":"Allow this command? [y/n]"}"# + "\n"
                    )
                ],
                nextAfterSeq: 7,
                hasMore: false
            )
        ]
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await model.refreshOnce()

        XCTAssertTrue(model.items.map(\.text).contains("Allow this command? [y/n]"))
        XCTAssertTrue(client.sentInputs.isEmpty)
    }

    func testStopKillsDaemonSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")

        await model.stop()

        XCTAssertTrue(client.sentInputs.isEmpty)
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
    }

    func testStopOfDeadSessionAllowsFreshLaunch() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        client.killError = .sessionNotLive

        await model.stop()

        client.killError = nil
        await model.send(prompt: "second", projectRoot: "/srv/repo")
        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
    }
}
