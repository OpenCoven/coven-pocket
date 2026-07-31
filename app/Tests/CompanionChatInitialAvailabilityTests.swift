import Combine
import XCTest
@testable import CovenPocket

@MainActor
final class CompanionChatInitialAvailabilityTests: XCTestCase {
    func testInitialAvailabilityIsIdleWithoutTerminalHistory() {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)

        XCTAssertEqual(model.availability, .idle)
        XCTAssertNil(model.lastTerminalAvailability)
        XCTAssertFalse(model.isAvailable)
    }

    func testCancelledNewestOverlappingInitialRefreshRestoresIdle() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)

        let first = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        let second = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.secondGateRequested], timeout: 1)

        second.cancel()
        client.resumeLastGate(with: .ready(pairedDaemon()))
        let secondPublished = await second.value
        client.resumeNextGate(
            with: .blocked(reason: "Stale", hint: "Ignore.")
        )
        let firstPublished = await first.value

        XCTAssertFalse(secondPublished)
        XCTAssertFalse(firstPublished)
        XCTAssertEqual(model.availability, .idle)
        XCTAssertNil(model.lastTerminalAvailability)
    }

    func testCancelledInitialRefreshRestoresIdle() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)

        let refresh = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)

        refresh.cancel()
        client.resumeNextGate(with: .ready(pairedDaemon()))
        let published = await refresh.value

        XCTAssertFalse(published)
        XCTAssertEqual(model.availability, .idle)
        XCTAssertNil(model.lastTerminalAvailability)
    }

    func testCancelledInitialRefreshRestoresIdleBeforeGateCompletes() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)
        let restored = XCTestExpectation(description: "availability restored")
        let observation = model.$availability
            .dropFirst()
            .sink { availability in
                if availability == .idle {
                    restored.fulfill()
                }
            }

        let refresh = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)

        refresh.cancel()
        await fulfillment(of: [restored], timeout: 1)

        XCTAssertEqual(model.availability, .idle)
        client.resumeNextGate(with: .ready(pairedDaemon()))
        let published = await refresh.value
        XCTAssertFalse(published)
        withExtendedLifetime(observation) {}
    }

    func testCancelledInitialSendGateRestoresIdleWithoutLaunchOrError() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.gateRequested], timeout: 1)

        send.cancel()
        client.resumeNextGate(
            with: .blocked(reason: "Stale", hint: "Ignore.")
        )
        await send.value

        XCTAssertEqual(model.availability, .idle)
        XCTAssertTrue(client.launchedPrompts.isEmpty)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
    }

    func testCancellationAfterReadyPublicationPreventsLaunch() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        let model = CompanionChatModel(client: client)
        var send: Task<Void, Never>?
        let observation = model.$availability
            .dropFirst()
            .sink { availability in
                if case .ready = availability {
                    send?.cancel()
                }
            }

        send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        guard let send else {
            XCTFail("Expected send task")
            return
        }
        await send.value

        XCTAssertEqual(model.availability, .ready(pairing))
        XCTAssertEqual(client.gateCallCount, 1)
        XCTAssertTrue(client.launchedPrompts.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRetry)
        withExtendedLifetime(observation) {}
    }

    func testCancelledInitialCleanupGateRestoresIdleWithoutKillOrError() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)

        let cleanup = Task {
            await model.beginCleanup(
                of: remoteSession(),
                pairing: nil,
                completionText: nil
            )
        }
        await fulfillment(of: [client.gateRequested], timeout: 1)

        cleanup.cancel()
        client.resumeNextGate(
            with: .blocked(reason: "Stale", hint: "Ignore.")
        )
        let cleaned = await cleanup.value

        XCTAssertFalse(cleaned)
        XCTAssertEqual(model.availability, .idle)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
    }

    func testResetInitialCleanupGateRestoresIdleWithoutKillOrError() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)
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
        XCTAssertEqual(model.availability, .idle)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
    }

    func testOlderCompletionCannotOverwriteNewerReady() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)

        let first = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        let second = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.secondGateRequested], timeout: 1)

        client.resumeLastGate(with: .ready(pairing))
        let secondPublished = await second.value
        client.resumeNextGate(
            with: .blocked(reason: "Stale", hint: "Ignore.")
        )
        let firstPublished = await first.value

        XCTAssertTrue(secondPublished)
        XCTAssertFalse(firstPublished)
        XCTAssertEqual(model.availability, .ready(pairing))
    }

    func testRefreshRecoversFromIdleToReady() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)

        let cancelled = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        cancelled.cancel()
        client.resumeNextGate(with: .ready(pairing))
        let cancelledPublished = await cancelled.value
        XCTAssertFalse(cancelledPublished)
        XCTAssertEqual(model.availability, .idle)

        client.suspendsGate = false
        let published = await model.refreshAvailability()

        XCTAssertTrue(published)
        XCTAssertEqual(model.availability, .ready(pairing))
        XCTAssertEqual(model.lastTerminalAvailability, .ready(pairing))
    }
}
