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

    func testCancelledRefreshReturnsFalseWithoutPublishingGate() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)

        let refresh = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)

        refresh.cancel()
        client.resumeNextGate(with: .ready(pairedDaemon()))
        let published = await refresh.value

        XCTAssertFalse(published)
        XCTAssertEqual(model.availability, .checking)
    }
}
