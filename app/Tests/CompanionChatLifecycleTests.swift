import XCTest
@testable import CovenPocket

@MainActor
// swiftlint:disable:next type_body_length
final class CompanionChatLifecycleTests: XCTestCase {
    func testStopUsesDaemonKill() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        let gateCallsBeforeStop = client.gateCallCount

        await model.stop()

        XCTAssertEqual(client.gateCallCount, gateCallsBeforeStop + 1)
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

    func testFailedStopRetainsSessionForCleanupRetryAndBlocksSend() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        client.killError = .polling

        await model.stop()

        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertTrue(model.canRetry)
        await model.send(prompt: "second", projectRoot: "/srv/repo")
        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertTrue(client.sentInputs.isEmpty)

        client.killError = nil
        await model.retry()
        XCTAssertFalse(model.hasPendingCleanup)
        await model.send(prompt: "second", projectRoot: "/srv/repo")
        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
    }

    func testStopKeepsSendBlockedUntilKillCompletes() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        client.suspendsKill = true

        let stop = Task { await model.stop() }
        await fulfillment(of: [client.killRequested], timeout: 1)
        XCTAssertTrue(model.isBusy)
        await model.send(prompt: "second", projectRoot: "/srv/repo")
        XCTAssertEqual(client.launchedPrompts, ["first"])

        client.resumeKill()
        await stop.value
        XCTAssertFalse(model.isBusy)
        await model.send(prompt: "second", projectRoot: "/srv/repo")
        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
    }

    func testResetRetainsSessionWhenCleanupGateIsBlocked() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        client.gate = .blocked(reason: "Unavailable", hint: "Reconnect.")

        await model.reset()

        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.items.last?.kind, .error)

        client.gate = .ready(pairedDaemon())
        await model.retry()
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
    }

    func testResetRestoresBlockedAvailabilityForSuspendedCleanupGate() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)
        let prior = CompanionChatModel.Availability.blocked(
            reason: "Offline",
            hint: "Reconnect."
        )
        model.availability = prior
        let generation = model.operationGeneration

        let cleanup = Task {
            await model.cleanupPairing(
                generation: generation,
                session: remoteSession(),
                completionText: nil
            )
        }
        await fulfillment(of: [client.gateRequested], timeout: 1)

        await model.reset()
        client.resumeNextGate(
            with: .blocked(reason: "Stale", hint: "Ignore.")
        )
        let verified = await cleanup.value

        XCTAssertNil(verified)
        XCTAssertEqual(model.availability, prior)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
    }

    func testInvalidatedLateLaunchKillFailureIsRetryable() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(
                prompt: "first",
                projectRoot: "/srv/repo",
                familiarID: "sage"
            )
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)
        await model.stop()
        XCTAssertTrue(model.isBusy)
        let gateCallsBeforeCleanup = client.gateCallCount

        client.killError = .polling
        client.resumeLaunch()
        await send.value

        XCTAssertEqual(client.gateCallCount, gateCallsBeforeCleanup + 1)
        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertTrue(model.canRetry)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.sessionFamiliarID)

        client.killError = nil
        await model.retry()
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
    }

    func testCancelledLateLaunchCleansWithoutAdoptingAndLaterSendRecovers() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(
                prompt: "first",
                projectRoot: "/srv/repo",
                familiarID: "sage"
            )
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)

        send.cancel()
        client.resumeLaunch()
        await send.value

        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertNil(model.session)
        XCTAssertNil(model.sessionFamiliarID)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRetry)

        await model.send(
            prompt: "second",
            projectRoot: "/srv/repo",
            familiarID: "forge"
        )

        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
        XCTAssertEqual(model.sessionFamiliarID, "forge")
        XCTAssertTrue(model.hasActivePollTask)
    }

    func testResetDoesNotDuplicateSuspendedCancelledLaunchCleanup() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsLaunch = true
        client.suspendsKill = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)
        send.cancel()
        client.resumeLaunch()
        await fulfillment(of: [client.killRequested], timeout: 1)

        client.suspendsKill = false
        await model.reset()

        XCTAssertEqual(
            client.operationLog.filter { $0 == "kill:session-1" }.count,
            1
        )

        client.resumeKill()
        await send.value

        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertFalse(model.isBusy)
    }

    func testCancellationBeforeActiveSessionInputPreventsRequest() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        var send: Task<Void, Never>?
        let observation = model.$availability
            .dropFirst()
            .sink { availability in
                if case .ready = availability {
                    send?.cancel()
                }
            }

        send = Task {
            await model.send(prompt: "second", projectRoot: "/srv/repo")
        }
        guard let send else {
            XCTFail("Expected send task")
            return
        }
        await send.value

        XCTAssertTrue(client.sentInputs.isEmpty)
        XCTAssertNotNil(model.session)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRetry)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
        withExtendedLifetime(observation) {}
    }

    func testCancellationDuringActiveSessionInputDoesNotRestartPolling() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        client.suspendsSendInput = true

        let send = Task {
            await model.send(prompt: "second", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.sendInputRequested], timeout: 1)

        send.cancel()
        client.resumeSendInput()
        await send.value

        XCTAssertEqual(client.sentInputs, ["second"])
        XCTAssertNotNil(model.session)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRetry)
        XCTAssertFalse(model.items.contains { $0.kind == .error })

        await model.send(prompt: "third", projectRoot: "/srv/repo")

        XCTAssertEqual(client.sentInputs, ["second", "third"])
        XCTAssertTrue(model.hasActivePollTask)
    }

    func testInvalidatedLaunchFailureClearsBusyState() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)
        await model.stop()
        client.launchError = .polling
        client.resumeLaunch()
        await send.value

        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.hasPendingCleanup)
    }

    func testLateLaunchCleanupRetainsSessionWhenPairingChanges() async {
        let originalPairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(originalPairing))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)
        await model.stop()
        client.gate = .ready(pairedDaemon(host: "other.tailnet.ts.net"))
        client.resumeLaunch()
        await send.value

        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertTrue(model.canRetry)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)

        client.gate = .ready(originalPairing)
        await model.retry()
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
    }

    func testLateLaunchCleanupCompletesWhenSameDaemonRestarts() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)
        await model.stop()
        client.gate = .ready(pairedDaemon(pid: 43, startedAt: "later"))
        client.resumeLaunch()
        await send.value

        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
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

}
