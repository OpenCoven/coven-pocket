import XCTest
@testable import CovenPocket

@MainActor
final class CompanionChatCleanupOwnershipTests: XCTestCase {
    func testRoutedResetCoalescesAndRouteInvalidationCannotCancelKill() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        client.suspendsKill = true
        client.killChecksCancellation = true
        let coordinator = ChatRouteGenerationCoordinator()
        var resetCount = 0

        coordinator.launchRoutedReset(for: .companionClaude) {
            resetCount += 1
            await model.reset()
        }
        await fulfillment(of: [client.killRequested], timeout: 1)
        coordinator.launchRoutedReset(for: .companionClaude) {
            resetCount += 1
            await model.reset()
        }
        coordinator.invalidate()

        XCTAssertEqual(
            client.operationLog.filter { $0 == "kill:session-1" }.count,
            1
        )
        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertTrue(model.isBusy)

        client.resumeKill()
        await coordinator.waitForRoutedReset()

        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRetry)
    }

    func testResetJoinsSuspendedCleanupBeforePairingAndDoesNotKillTwice() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.suspendsKill = true
        let model = CompanionChatModel(client: client)
        model.availability = .ready(pairing)
        let session = remoteSession()

        let cleanup = Task {
            await model.beginCleanup(
                of: session,
                pairing: pairing,
                completionText: nil,
                verifiedPairing: verifiedPairingToken(pairing, on: model)
            )
        }
        await fulfillment(of: [client.killRequested], timeout: 1)

        client.suspendsGate = true
        let generation = model.operationGeneration
        let reset = Task { await model.reset() }
        while model.operationGeneration == generation {
            await Task.yield()
        }

        client.resumeKill()
        let cleaned = await cleanup.value
        XCTAssertTrue(cleaned)
        client.resumeNextGate(with: .ready(pairing))
        await reset.value

        XCTAssertEqual(client.gateCallCount, 0)
        XCTAssertEqual(
            client.operationLog.filter { $0 == "kill:session-1" }.count,
            1
        )
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRetry)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testLateBlockedCleanupRetryIsBenignAfterOwnerSucceeds() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.suspendsKill = true
        let model = CompanionChatModel(client: client)
        let priorAvailability = CompanionChatModel.Availability.ready(pairing)
        model.availability = priorAvailability
        let session = remoteSession()

        let cleanup = Task {
            await model.beginCleanup(
                of: session,
                pairing: pairing,
                completionText: nil,
                verifiedPairing: verifiedPairingToken(pairing, on: model)
            )
        }
        await fulfillment(of: [client.killRequested], timeout: 1)

        client.suspendsGate = true
        let generation = model.operationGeneration
        let reset = Task { await model.reset() }
        while model.operationGeneration == generation {
            await Task.yield()
        }

        client.resumeKill()
        let cleaned = await cleanup.value
        XCTAssertTrue(cleaned)
        client.resumeNextGate(
            with: .blocked(reason: "Unavailable", hint: "Reconnect.")
        )
        await reset.value

        XCTAssertEqual(client.gateCallCount, 0)
        XCTAssertEqual(
            client.operationLog.filter { $0 == "kill:session-1" }.count,
            1
        )
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRetry)
        XCTAssertEqual(model.availability, priorAvailability)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testConcurrentCleanupRetryJoinsOwnerWithoutMutatingPendingState() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.suspendsKill = true
        let model = CompanionChatModel(client: client)
        model.availability = .ready(pairing)
        let session = remoteSession()

        let cleanup = Task {
            await model.beginCleanup(
                of: session,
                pairing: pairing,
                completionText: nil,
                verifiedPairing: verifiedPairingToken(pairing, on: model)
            )
        }
        await fulfillment(of: [client.killRequested], timeout: 1)

        client.suspendsGate = true
        let retryStarted = expectation(description: "cleanup retry started")
        let retry = Task {
            retryStarted.fulfill()
            await model.retryPendingCleanup()
        }
        await fulfillment(of: [retryStarted], timeout: 1)

        XCTAssertEqual(client.gateCallCount, 0)
        XCTAssertEqual(
            client.operationLog.filter { $0 == "kill:session-1" }.count,
            1
        )
        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canRetry)
        XCTAssertTrue(model.items.isEmpty)

        client.resumeKill()
        let cleaned = await cleanup.value
        XCTAssertTrue(cleaned)
        client.resumeNextGate(with: .ready(pairing))
        await retry.value

        XCTAssertEqual(
            client.operationLog.filter { $0 == "kill:session-1" }.count,
            1
        )
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRetry)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testNewerCheckingBeforeGateResponsePreventsCleanupKillSideEffect() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        let model = CompanionChatModel(client: client)
        client.beforeGateResponse = {
            _ = model.beginAvailabilityCheck()
        }

        let cleaned = await model.beginCleanup(
            of: remoteSession(),
            pairing: pairing,
            completionText: nil
        )

        XCTAssertFalse(cleaned)
        XCTAssertEqual(model.availability, .checking)
        XCTAssertTrue(client.killPairings.isEmpty)
        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.canRetry)
    }

    func testStaleCleanupCompletionCannotClearNewerBLaunchState() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.suspendsKill = true
        let model = CompanionChatModel(client: client)
        model.availability = .ready(pairingA)

        let cleanup = Task {
            await model.beginCleanup(
                of: remoteSession(id: "session-a"),
                pairing: pairingA,
                completionText: nil,
                verifiedPairing: verifiedPairingToken(pairingA, on: model)
            )
        }
        await fulfillment(of: [client.killRequested], timeout: 1)

        model.operationGeneration &+= 1
        model.availability = .ready(pairingB)
        model.adoptLaunchedSession(
            remoteSession(id: "session-b"),
            context: CompanionSendContext(
                prompt: "newer",
                projectRoot: "/srv/repo",
                familiarID: nil,
                familiarPresentation: .empty
            ),
            pairing: verifiedPairingToken(pairingB, on: model)
        )
        model.pairing = pairingB
        model.isBusy = true
        model.startPolling()

        client.resumeKill()
        let cleaned = await cleanup.value

        XCTAssertTrue(cleaned)
        XCTAssertEqual(model.availability, .ready(pairingB))
        XCTAssertEqual(model.session?.id, "session-b")
        XCTAssertEqual(model.pairing, pairingB)
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canRetry)
        XCTAssertFalse(model.hasPendingCleanup)

        client.gate = .ready(pairingB)
        await model.reset()
    }
}
