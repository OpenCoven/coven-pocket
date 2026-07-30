import XCTest
@testable import CovenPocket

@MainActor
final class CompanionPollingRetryAvailabilityTests: XCTestCase {
    func testCancelledPollingRetryGateRestoresPollingRetry() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.suspendsGate = true
        let model = CompanionChatModel(client: client)
        let prior = CompanionChatModel.Availability.ready(pairing)
        model.availability = prior
        model.pairing = pairing
        model.session = remoteSession()
        model.retriesPolling = true
        model.canRetry = true

        let retry = Task { await model.retryPolling() }
        await fulfillment(of: [client.gateRequested], timeout: 1)

        retry.cancel()
        client.resumeNextGate(
            with: .blocked(reason: "Stale", hint: "Ignore.")
        )
        await retry.value

        XCTAssertEqual(model.availability, prior)
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.pairing, pairing)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.retriesPolling)
        XCTAssertTrue(model.canRetry)
    }

    func testPollingRetryCancelledByBlockedGateRestoresReady() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(
            gate: .blocked(reason: "Stale", hint: "Ignore.")
        )
        let model = CompanionChatModel(client: client)
        let prior = CompanionChatModel.Availability.ready(pairing)
        model.availability = prior
        model.pairing = pairing
        model.session = remoteSession()
        model.retriesPolling = true
        model.canRetry = true
        var retry: Task<Void, Never>?
        let observation = model.$availability
            .dropFirst()
            .sink { availability in
                if case .blocked = availability {
                    retry?.cancel()
                }
            }

        retry = Task { await model.retryPolling() }
        await retry?.value

        XCTAssertEqual(model.availability, prior)
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.pairing, pairing)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.retriesPolling)
        XCTAssertTrue(model.canRetry)
        withExtendedLifetime(observation) {}
    }

    func testPollingRetryCancelledByBlockedGateRestoresIdle() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(
            gate: .blocked(reason: "Stale", hint: "Ignore.")
        )
        let model = CompanionChatModel(client: client)
        model.pairing = pairing
        model.session = remoteSession()
        model.retriesPolling = true
        model.canRetry = true
        var retry: Task<Void, Never>?
        let observation = model.$availability
            .dropFirst()
            .sink { availability in
                if case .blocked = availability {
                    retry?.cancel()
                }
            }

        retry = Task { await model.retryPolling() }
        await retry?.value
        await Task.yield()

        XCTAssertEqual(model.availability, .idle)
        XCTAssertNil(model.lastTerminalAvailability)
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.retriesPolling)
        XCTAssertTrue(model.canRetry)
        withExtendedLifetime(observation) {}
    }
}

@MainActor
final class CompanionChatPollingCancellationTests: XCTestCase {
    func testCancellationAfterCompletedRefreshDoesNotRestoreRetry() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.eventBatches = [
            RemoteEventBatch(
                events: [
                    RemoteEvent(
                        seq: 1,
                        kind: "result",
                        payloadJson: #"{"type":"result","is_error":false}"#,
                        createdAt: "t"
                    )
                ],
                nextAfterSeq: 1,
                hasMore: false
            )
        ]
        let model = CompanionChatModel(client: client)
        model.availability = .ready(pairing)
        model.pairing = pairing
        model.session = remoteSession()
        model.retriesPolling = true
        model.canRetry = true
        var retry: Task<Void, Never>?
        let observation = model.$items
            .dropFirst()
            .sink { items in
                if items.contains(where: { $0.text == "Turn complete" }) {
                    retry?.cancel()
                }
            }

        retry = Task { await model.retryPolling() }
        await retry?.value

        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.items.map(\.text), ["Turn complete"])
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.retriesPolling)
        XCTAssertFalse(model.canRetry)
        withExtendedLifetime(observation) {}
    }

    func testCancelledPollingRetryRestoresRetryWithoutApplyingEvents() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.suspendsEvents = true
        let model = CompanionChatModel(client: client)
        model.availability = .ready(pairing)
        model.pairing = pairing
        model.session = remoteSession()
        model.retriesPolling = true
        model.canRetry = true

        let retry = Task { await model.retryPolling() }
        await fulfillment(of: [client.eventsRequested], timeout: 1)

        retry.cancel()
        client.resumeEvents(
            with: RemoteEventBatch(
                events: [
                    RemoteEvent(
                        seq: 1,
                        kind: "assistant",
                        payloadJson: #"{"type":"assistant","message":{"content":"#
                            + #"[{"type":"text","text":"Stale"}]}}"#,
                        createdAt: "t"
                    )
                ],
                nextAfterSeq: 1,
                hasMore: false
            )
        )
        await retry.value

        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.pairing, pairing)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.cursor, 0)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.retriesPolling)
        XCTAssertTrue(model.canRetry)
    }

    func testCancelledPollingRetryWithoutSessionClearsBusyAndRetry() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.suspendsEvents = true
        let model = CompanionChatModel(client: client)
        model.availability = .ready(pairing)
        model.pairing = pairing
        model.session = remoteSession()
        model.retriesPolling = true
        model.canRetry = true

        let retry = Task { await model.retryPolling() }
        await fulfillment(of: [client.eventsRequested], timeout: 1)

        model.session = nil
        retry.cancel()
        client.resumeEvents(
            with: RemoteEventBatch(
                events: [],
                nextAfterSeq: 0,
                hasMore: false
            )
        )
        await retry.value

        XCTAssertNil(model.session)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.retriesPolling)
        XCTAssertFalse(model.canRetry)
    }

    func testStalePollingRetryCannotMutateNewerSendState() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.suspendsEvents = true
        let model = CompanionChatModel(client: client)
        model.availability = .ready(pairing)
        model.pairing = pairing
        model.session = remoteSession()
        model.retriesPolling = true
        model.canRetry = true

        let retry = Task { await model.retryPolling() }
        await fulfillment(of: [client.eventsRequested], timeout: 1)

        client.suspendsEvents = false
        await model.reset()
        await model.send(prompt: "newer", projectRoot: "/srv/repo")
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.hasActivePollTask)

        client.resumeEvents(
            with: RemoteEventBatch(
                events: [
                    RemoteEvent(
                        seq: 1,
                        kind: "assistant",
                        payloadJson: #"{"type":"assistant","message":{"content":"#
                            + #"[{"type":"text","text":"Stale"}]}}"#,
                        createdAt: "t"
                    )
                ],
                nextAfterSeq: 1,
                hasMore: false
            )
        )
        await retry.value

        XCTAssertNotNil(model.session)
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertFalse(model.items.contains { $0.text == "Stale" })
        XCTAssertEqual(model.cursor, 0)

        await model.reset()
    }
}
