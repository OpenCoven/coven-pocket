import XCTest
@testable import CovenPocket

@MainActor
final class CompanionChatCleanupOwnershipTests: XCTestCase {
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
                verifiedPairing: pairing
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
                verifiedPairing: pairing
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
        let session = remoteSession()

        let cleanup = Task {
            await model.beginCleanup(
                of: session,
                pairing: pairing,
                completionText: nil,
                verifiedPairing: pairing
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
}
