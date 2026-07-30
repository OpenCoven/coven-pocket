import XCTest
@testable import CovenPocket

@MainActor
final class CompanionChatFamiliarTests: XCTestCase {
    func testChangingFamiliarKillsOldSessionBeforeLaunchingReplacement() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )
        completeTurn(on: model)

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "forge"
        )

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "forge"])
        XCTAssertEqual(
            client.operationLog,
            ["launch:sage", "kill:session-1", "launch:forge"]
        )
        XCTAssertEqual(model.sessionFamiliarID, "forge")
    }

    func testSameProjectAndFamiliarReuseSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )
        completeTurn(on: model)

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
        XCTAssertEqual(client.sentInputs, ["second"])
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
    }

    func testAddingFamiliarReplacesIdentitylessSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        XCTAssertEqual(client.launchedFamiliarIDs, [nil, "sage"])
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
    }

    func testRemovingFamiliarReplacesBoundSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )
        completeTurn(on: model)

        await model.send(prompt: "second", projectRoot: "/srv/repo")

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", nil])
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
    }

    func testFamiliarIDIsTrimmedWithoutChangingCaseAndBlankIsNil() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "  SaGe \n"
        )
        completeTurn(on: model)

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: " \t\n "
        )

        XCTAssertEqual(client.launchedFamiliarIDs, ["SaGe", nil])
        XCTAssertNil(model.sessionFamiliarID)
    }

    func testGateFailureRetryUsesOriginalFamiliar() async {
        let client = FakeCompanionSessionClient(gate: .notPaired)
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)
        let firstSend = Task {
            await model.send(
                prompt: "first",
                projectRoot: "/srv/repo",
                familiarID: "sage"
            )
        }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        await model.send(
            prompt: "ignored",
            projectRoot: "/srv/repo",
            familiarID: "forge"
        )
        client.resumeNextGate(with: .notPaired)
        await firstSend.value

        XCTAssertEqual(model.retryFamiliarID, "sage")
        client.suspendsGate = false
        client.gate = .ready(pairedDaemon())
        await model.retry()

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
    }

    func testLaunchFailureRetryUsesOriginalFamiliar() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.launchError = .polling
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        XCTAssertEqual(model.retryFamiliarID, "sage")
        client.launchError = nil
        await model.retry()

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "sage"])
    }

    func testFamiliarChangeKillFailureBlocksReplacementAndRetriesIdentity() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )
        completeTurn(on: model)
        client.killError = .polling

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "forge"
        )

        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertEqual(model.retryFamiliarID, "forge")
        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])

        await model.retry()
        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertEqual(model.retryFamiliarID, "forge")

        client.killError = nil
        await model.retry()

        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "forge"])
        XCTAssertEqual(model.sessionFamiliarID, "forge")
    }
}

@MainActor
final class CompanionChatFamiliarAuthorityTests: XCTestCase {
    func testMissingFamiliarEchoFailsLaunchAndCleansRemoteSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.echoesRequestedFamiliarID = false
        let model = CompanionChatModel(client: client)

        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        XCTAssertNil(model.session)
        XCTAssertNil(model.sessionFamiliarID)
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertTrue(model.canRetry)
        XCTAssertTrue(
            model.items.contains {
                $0.kind == .error
                    && $0.text.contains("did not confirm the selected familiar")
            }
        )

        client.echoesRequestedFamiliarID = true
        await model.retry()

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "sage"])
        XCTAssertEqual(model.sessionFamiliarID, "sage")
    }

    func testMismatchedFamiliarEchoAndCleanupFailureBlockTraffic() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.echoesRequestedFamiliarID = false
        client.launchResponseFamiliarID = "forge"
        client.killError = .polling
        let model = CompanionChatModel(client: client)

        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertEqual(model.retryFamiliarID, "sage")
        XCTAssertTrue(
            model.items.contains {
                $0.kind == .error
                    && $0.text.contains("did not confirm the selected familiar")
            }
        )

        await model.send(
            prompt: "blocked",
            projectRoot: "/srv/repo",
            familiarID: "forge"
        )

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
        XCTAssertTrue(client.sentInputs.isEmpty)
    }

    func testNilFamiliarEchoIsValidForNilRequest() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)

        await model.send(prompt: "first", projectRoot: "/srv/repo")

        XCTAssertNotNil(model.session)
        XCTAssertNil(model.sessionFamiliarID)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
    }

    func testDeadSessionRetryRelaunchesWithOriginalFamiliar() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )
        completeTurn(on: model)
        client.sendInputError = .sessionNotLive

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        XCTAssertEqual(model.retryFamiliarID, "sage")
        client.sendInputError = nil
        await model.retry()

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage", "sage"])
        XCTAssertEqual(model.sessionFamiliarID, "sage")
    }

    func testAbandonSessionClearsFamiliarBinding() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )

        model.abandonSession()

        XCTAssertNil(model.session)
        XCTAssertNil(model.sessionFamiliarID)
    }

    func testStaleCleanupCompletionCannotOverwriteNewFamiliarBinding() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsKill = true
        let model = CompanionChatModel(client: client)
        let staleSession = remoteSession(id: "stale", familiarID: "sage")
        model.operationGeneration = 1

        let cleanup = Task {
            await model.beginCleanup(
                of: staleSession,
                pairing: pairedDaemon(),
                completionText: nil
            )
        }
        await fulfillment(of: [client.killRequested], timeout: 1)
        model.operationGeneration = 2
        model.session = remoteSession(id: "current", familiarID: "forge")
        model.sessionFamiliarID = "forge"

        client.resumeKill()
        await cleanup.value

        XCTAssertEqual(model.session?.id, "current")
        XCTAssertEqual(model.sessionFamiliarID, "forge")
    }

    func testStopInvalidatesSuspendedCleanupRetryBeforeItCanRelaunch() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(
            prompt: "first",
            projectRoot: "/srv/repo",
            familiarID: "sage"
        )
        completeTurn(on: model)
        client.killError = .polling
        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "forge"
        )
        client.killError = nil
        client.suspendsGate = true

        let retry = Task { await model.retry() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        let stop = Task { await model.stop() }
        await fulfillment(of: [client.secondGateRequested], timeout: 1)

        client.resumeLastGate(with: .ready(pairedDaemon()))
        await stop.value
        client.suspendsGate = false
        client.resumeNextGate(with: .ready(pairedDaemon()))
        await retry.value

        XCTAssertEqual(client.launchedFamiliarIDs, ["sage"])
        XCTAssertNil(model.session)
        XCTAssertNil(model.retryFamiliarID)
    }
}
