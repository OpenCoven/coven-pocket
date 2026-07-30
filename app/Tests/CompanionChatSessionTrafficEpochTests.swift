// swiftlint:disable file_length

import XCTest
@testable import CovenPocket

@MainActor
// swiftlint:disable:next type_body_length
final class CompanionChatSessionTrafficEpochTests: XCTestCase {
    func testSuspendedSameInstanceRefreshPreservesPollAndReusesSession() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        let requestGeneration = model.availabilityGeneration
        let trafficEpoch = model.trafficEpoch

        client.suspendsGate = true
        let refresh = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        XCTAssertEqual(model.availability, .checking)
        XCTAssertEqual(model.availabilityGeneration, requestGeneration + 1)
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)

        await model.refreshOnce()

        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.pairing, pairing)
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)

        client.resumeNextGate(with: .ready(pairing))
        let published = await refresh.value
        client.suspendsGate = false

        XCTAssertTrue(published)
        XCTAssertEqual(model.availability, .ready(pairing))
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)
        XCTAssertEqual(model.sessionVerifiedPairing?.trafficEpoch, trafficEpoch)
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)

        await model.send(prompt: "second", projectRoot: "/srv/repo")

        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertEqual(client.sentInputs, ["second"])
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        await model.reset()
    }

    func testOverlappingSettingsRefreshesPreserveSameInstanceSession() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        let requestGeneration = model.availabilityGeneration
        let trafficEpoch = model.trafficEpoch

        client.suspendsGate = true
        let first = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        let second = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.secondGateRequested], timeout: 1)
        XCTAssertEqual(model.availabilityGeneration, requestGeneration + 2)
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)

        await model.refreshOnce()

        client.resumeNextGate(with: .ready(pairing))
        let firstPublished = await first.value
        client.resumeNextGate(with: .ready(pairing))
        let secondPublished = await second.value

        XCTAssertFalse(firstPublished)
        XCTAssertTrue(secondPublished)
        XCTAssertEqual(model.availability, .ready(pairing))
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.pairing, pairing)
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        client.suspendsGate = false
        await model.reset()
    }

    func testSameInstanceRefreshDuringInputKeepsAdoptedSession() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        let trafficEpoch = model.trafficEpoch
        client.suspendsSendInput = true

        let send = Task {
            await model.send(prompt: "second", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.sendInputRequested], timeout: 1)

        let published = await model.refreshAvailability()
        XCTAssertTrue(published)
        client.resumeSendInput()
        await send.value

        XCTAssertEqual(client.sentInputs, ["second"])
        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.pairing, pairing)
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        XCTAssertFalse(model.canRetry)
        await model.reset()
    }

    func testSameInstanceRefreshStillHandlesSessionNotLiveInputFailure() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        client.suspendsSendInput = true

        let send = Task {
            await model.send(prompt: "second", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.sendInputRequested], timeout: 1)

        let published = await model.refreshAvailability()
        XCTAssertTrue(published)
        client.sendInputError = .sessionNotLive
        client.resumeSendInput()
        await send.value

        XCTAssertEqual(client.sentInputs, ["second"])
        XCTAssertNil(model.session)
        XCTAssertNil(model.pairing)
        XCTAssertNil(model.sessionVerifiedPairing)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.retryPrompt, "second")
        XCTAssertTrue(
            model.items.contains { $0.text.contains("Session is not running") }
        )
    }

    func testSameInstanceRefreshAfterInputFailureResumesPolling() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        client.suspendsSendInput = true

        let send = Task {
            await model.send(prompt: "second", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.sendInputRequested], timeout: 1)

        let published = await model.refreshAvailability()
        XCTAssertTrue(published)
        client.sendInputError = .polling
        client.resumeSendInput()
        await send.value

        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.pairing, pairing)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.retryPrompt, "second")
        model.apply(events: [
            RemoteEvent(
                seq: 2,
                kind: "result",
                payloadJson: #"{"type":"result","is_error":false}"#,
                createdAt: "t"
            )
        ])
        XCTAssertFalse(model.canRetry)
        XCTAssertNil(model.retryPrompt)
        await model.reset()
    }

    func testSameInstanceRefreshDuringContextCleanupLaunchesReplacement() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/one")
        completeTurn(on: model)
        client.suspendsKill = true

        let send = Task {
            await model.send(prompt: "second", projectRoot: "/srv/two")
        }
        await fulfillment(of: [client.killRequested], timeout: 1)

        let published = await model.refreshAvailability()
        XCTAssertTrue(published)
        client.resumeKill()
        await send.value

        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
        XCTAssertEqual(model.sessionProjectRoot, "/srv/two")
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertFalse(model.canRetry)
        await model.reset()
    }

    func testSameInstanceRefreshDuringReplacementLaunchAdoptsSession() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/one")
        completeTurn(on: model)
        client.suspendsKill = true
        client.suspendsLaunch = true

        let send = Task {
            await model.send(prompt: "second", projectRoot: "/srv/two")
        }
        await fulfillment(of: [client.killRequested], timeout: 1)
        client.resumeKill()
        await fulfillment(of: [client.secondLaunchRequested], timeout: 1)

        let published = await model.refreshAvailability()
        XCTAssertTrue(published)
        client.resumeLaunch(id: "session-2", projectRoot: "/srv/two")
        await send.value

        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
        XCTAssertEqual(model.session?.id, "session-2")
        XCTAssertEqual(model.sessionProjectRoot, "/srv/two")
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertFalse(model.canRetry)
        await model.reset()
    }

    func testSameInstanceRefreshAfterPollingFailureKeepsRetryOwnership() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        client.eventError = .polling
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        await model.refreshOnce()
        let trafficEpoch = model.trafficEpoch

        XCTAssertTrue(model.retriesPolling)
        XCTAssertTrue(model.canRetry)

        client.eventError = nil
        let published = await model.refreshAvailability()

        XCTAssertTrue(published)
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.pairing, pairing)
        XCTAssertTrue(model.retriesPolling)
        XCTAssertTrue(model.canRetry)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)

        await model.retry()

        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertFalse(model.retriesPolling)
        XCTAssertFalse(model.canRetry)
        await model.reset()
    }

    func testCancelledRefreshRestoresSameInstanceSessionTraffic() async {
        let pairing = pairedDaemon()
        let restarted = pairedDaemon(pid: 43, startedAt: "later")
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        let trafficEpoch = model.trafficEpoch

        client.suspendsGate = true
        let refresh = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        XCTAssertEqual(model.availability, .checking)
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)

        await model.refreshOnce()
        refresh.cancel()
        client.resumeNextGate(with: .ready(restarted))
        let published = await refresh.value

        XCTAssertFalse(published)
        XCTAssertEqual(model.availability, .ready(pairing))
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.pairing, pairing)
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        client.suspendsGate = false
        await model.reset()
    }

    func testCancelledBlockedPublishRestoresTrafficEpoch() async {
        let pairing = pairedDaemon()
        let client = FakeCompanionSessionClient(
            gate: .blocked(reason: "Stale", hint: "Ignore.")
        )
        let model = CompanionChatModel(client: client)
        model.availability = .ready(pairing)
        let trafficEpoch = model.trafficEpoch
        var refresh: Task<Bool, Never>?
        let observation = model.$availability
            .dropFirst()
            .sink { availability in
                if case .blocked = availability {
                    refresh?.cancel()
                }
            }

        refresh = Task { await model.refreshAvailability() }
        let published = await refresh?.value

        XCTAssertEqual(published, false)
        XCTAssertEqual(model.availability, .ready(pairing))
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)
        withExtendedLifetime(observation) {}
    }

    func testCancelledReadyPublishRestoresActiveSessionTrafficEpoch() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        let trafficEpoch = model.trafficEpoch
        client.gate = .ready(pairingB)
        var refresh: Task<Bool, Never>?
        let observation = model.$availability
            .dropFirst()
            .sink { availability in
                if availability == .ready(pairingB) {
                    refresh?.cancel()
                }
            }

        refresh = Task { await model.refreshAvailability() }
        let published = await refresh?.value

        XCTAssertEqual(published, false)
        XCTAssertEqual(model.availability, .ready(pairingA))
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.pairing, pairingA)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        withExtendedLifetime(observation) {}
        await model.reset()
    }

    func testDifferentEndpointInvalidatesSessionTrafficExactlyOnce() async {
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        await assertTerminalTransitionInvalidatesSession(
            gate: .ready(pairingB),
            expectedAvailability: .ready(pairingB)
        )
    }

    func testRestartedInstanceInvalidatesSessionTrafficExactlyOnce() async {
        let pairing = pairedDaemon()
        let restarted = pairedDaemon(pid: 43, startedAt: "later")
        let client = FakeCompanionSessionClient(gate: .ready(pairing))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        let trafficEpoch = model.trafficEpoch

        client.gate = .ready(restarted)
        let published = await model.refreshAvailability()
        let eventCount = client.eventPairings.count
        await model.refreshOnce()
        await model.refreshOnce()

        XCTAssertTrue(published)
        XCTAssertEqual(model.availability, .ready(restarted))
        XCTAssertEqual(model.trafficEpoch, trafficEpoch + 1)
        XCTAssertEqual(client.eventPairings.count, eventCount)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        XCTAssertTrue(client.killPairings.isEmpty)
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertNil(model.session)
        XCTAssertNil(model.pairing)
        XCTAssertFalse(model.hasActivePollTask)
    }

    func testBlockedAvailabilityInvalidatesSessionTrafficExactlyOnce() async {
        await assertTerminalTransitionInvalidatesSession(
            gate: .blocked(reason: "Unavailable", hint: "Reconnect."),
            expectedAvailability: .blocked(
                reason: "Unavailable",
                hint: "Reconnect."
            )
        )
    }

    func testNotPairedAvailabilityInvalidatesSessionTrafficExactlyOnce() async {
        await assertTerminalTransitionInvalidatesSession(
            gate: .notPaired,
            expectedAvailability: .blocked(
                reason: "Not paired",
                hint: "Pair with a daemon in the Companion tab first."
            )
        )
    }

    func testStaleOlderReadyCannotRestoreInvalidatedSessionTraffic() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        let trafficEpoch = model.trafficEpoch

        client.suspendsGate = true
        let older = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        let newer = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.secondGateRequested], timeout: 1)

        client.resumeLastGate(with: .ready(pairingB))
        let newerPublished = await newer.value
        XCTAssertEqual(model.trafficEpoch, trafficEpoch + 1)
        let eventCount = client.eventPairings.count
        client.resumeNextGate(with: .ready(pairingA))
        let olderPublished = await older.value
        await model.refreshOnce()
        await model.refreshOnce()

        XCTAssertTrue(newerPublished)
        XCTAssertFalse(olderPublished)
        XCTAssertEqual(model.availability, .ready(pairingB))
        XCTAssertEqual(model.trafficEpoch, trafficEpoch + 1)
        XCTAssertEqual(client.eventPairings.count, eventCount)
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertEqual(client.killPairings, [pairingA])
        XCTAssertNil(model.session)
        XCTAssertNil(model.pairing)
        XCTAssertFalse(model.hasActivePollTask)
    }

    private func assertTerminalTransitionInvalidatesSession(
        gate: CompanionModel.SessionGate,
        expectedAvailability: CompanionChatModel.Availability,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        let trafficEpoch = model.trafficEpoch

        client.gate = gate
        let published = await model.refreshAvailability()
        XCTAssertEqual(
            model.trafficEpoch,
            trafficEpoch + 1,
            file: file,
            line: line
        )
        let eventCount = client.eventPairings.count
        await model.refreshOnce()
        await model.refreshOnce()

        XCTAssertTrue(published, file: file, line: line)
        XCTAssertEqual(
            model.availability,
            expectedAvailability,
            file: file,
            line: line
        )
        XCTAssertEqual(
            client.eventPairings.count,
            eventCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            client.killedSessionIDs,
            ["session-1"],
            file: file,
            line: line
        )
        XCTAssertEqual(
            client.killPairings,
            [pairingA],
            file: file,
            line: line
        )
        XCTAssertNil(model.session, file: file, line: line)
        XCTAssertNil(model.pairing, file: file, line: line)
        XCTAssertFalse(model.hasActivePollTask, file: file, line: line)
    }
}
