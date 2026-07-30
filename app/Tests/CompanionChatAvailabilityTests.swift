import XCTest
@testable import CovenPocket

@MainActor
final class CompanionChatAvailabilityTests: XCTestCase {
    func testRefreshIsCheckingAndIgnoresOlderResult() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)

        let first = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        XCTAssertEqual(model.availability, .checking)
        let second = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.secondGateRequested], timeout: 1)

        client.resumeNextGate(with: .ready(pairedDaemon()))
        let firstPublished = await first.value
        client.resumeNextGate(
            with: .blocked(reason: "Unavailable", hint: "Reconnect.")
        )
        let secondPublished = await second.value

        XCTAssertFalse(firstPublished)
        XCTAssertTrue(secondPublished)
        XCTAssertEqual(
            model.availability,
            .blocked(reason: "Unavailable", hint: "Reconnect.")
        )
    }

    func testNewerRefreshSupersedesOperationalGate() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        let refresh = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.secondGateRequested], timeout: 1)

        client.resumeLastGate(
            with: .blocked(reason: "Unavailable", hint: "Reconnect.")
        )
        await refresh.value
        client.resumeNextGate(with: .ready(pairedDaemon()))
        await send.value

        XCTAssertEqual(
            model.availability,
            .blocked(reason: "Unavailable", hint: "Reconnect.")
        )
        XCTAssertTrue(client.launchedPrompts.isEmpty)
    }

    func testCancelledRefreshRestoresReadyAvailability() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)
        let prior = CompanionChatModel.Availability.ready(pairedDaemon())
        model.availability = prior

        let refresh = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)

        refresh.cancel()
        client.resumeNextGate(with: .ready(pairedDaemon()))
        let published = await refresh.value

        XCTAssertFalse(published)
        XCTAssertEqual(model.availability, prior)
    }

    func testCancelledRefreshRestoresBlockedAvailability() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)
        let prior = CompanionChatModel.Availability.blocked(
            reason: "Offline",
            hint: "Reconnect."
        )
        model.availability = prior

        let refresh = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)

        refresh.cancel()
        client.resumeNextGate(with: .ready(pairedDaemon()))
        let published = await refresh.value

        XCTAssertFalse(published)
        XCTAssertEqual(model.availability, prior)
    }

    func testRefreshCancelledBeforeStartLeavesAvailabilityUnchanged() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let model = CompanionChatModel(client: client)
        let prior = CompanionChatModel.Availability.blocked(
            reason: "Offline",
            hint: "Reconnect."
        )
        model.availability = prior

        let refresh = Task { await model.refreshAvailability() }
        refresh.cancel()
        let published = await refresh.value

        XCTAssertFalse(published)
        XCTAssertEqual(client.gateCallCount, 0)
        XCTAssertEqual(model.availability, prior)
    }

    func testOlderCancelledRefreshCannotRestoreOverNewerResult() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)
        model.availability = .ready(pairedDaemon())

        let first = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        let second = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.secondGateRequested], timeout: 1)

        first.cancel()
        client.resumeLastGate(
            with: .blocked(reason: "Unavailable", hint: "Reconnect.")
        )
        let secondPublished = await second.value
        client.resumeNextGate(with: .ready(pairedDaemon()))
        let firstPublished = await first.value

        XCTAssertTrue(secondPublished)
        XCTAssertFalse(firstPublished)
        XCTAssertEqual(
            model.availability,
            .blocked(reason: "Unavailable", hint: "Reconnect.")
        )
    }

    func testCancelledNewerRefreshRestoresLastTerminalAvailability() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)
        let prior = CompanionChatModel.Availability.ready(pairedDaemon())
        model.availability = prior

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
        XCTAssertEqual(model.availability, prior)
    }
}
