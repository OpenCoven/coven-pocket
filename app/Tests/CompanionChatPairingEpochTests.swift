import XCTest
@testable import CovenPocket

@MainActor
// swiftlint:disable:next type_body_length
final class CompanionChatPairingEpochTests: XCTestCase {
    func testCleanupRetryRetainsPromptForItsVerifiedDaemon() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/a")
        completeTurn(on: model)

        client.gate = .ready(pairingB)
        await model.send(prompt: "second", projectRoot: "/srv/b")

        XCTAssertTrue(model.hasPendingCleanup)
        XCTAssertEqual(model.retryPrompt, "second")

        client.gate = .ready(pairingA)
        await model.retry()

        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertEqual(client.launchedPrompts, ["first"])
        XCTAssertEqual(model.retryPrompt, "second")
        XCTAssertTrue(model.canRetry)

        client.gate = .ready(pairingB)
        await model.retry()

        XCTAssertEqual(client.launchedPrompts, ["first", "second"])
        XCTAssertEqual(client.launchedPairings, [pairingA, pairingB])
    }

    func testReadyEndpointSupersedesSuspendedLaunchAndRetryRequiresOriginalDaemon() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)

        client.gate = .ready(pairingB)
        let refreshed = await model.refreshAvailability()
        XCTAssertTrue(refreshed)
        client.resumeLaunch(id: "session-a")
        await send.value

        XCTAssertEqual(model.availability, .ready(pairingB))
        XCTAssertEqual(client.killedSessionIDs, ["session-a"])
        XCTAssertEqual(client.killPairings, [pairingA])
        XCTAssertNil(model.session)
        XCTAssertNil(model.pairing)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.retryPrompt, "first")
        XCTAssertFalse(model.items.contains { $0.kind == .error })

        await model.retry()

        XCTAssertEqual(client.launchedPairings, [pairingA])
        XCTAssertEqual(model.retryPrompt, "first")
        XCTAssertTrue(model.canRetry)

        client.gate = .ready(pairingA)
        await model.retry()

        XCTAssertEqual(client.launchedPairings, [pairingA, pairingA])
        XCTAssertEqual(model.pairing, pairingA)
        XCTAssertNotNil(model.session)
        XCTAssertTrue(model.hasActivePollTask)
        await model.reset()
    }

    func testRestartedDaemonSupersedesSuspendedLaunchAtSameEndpoint() async {
        let pairingA = pairedDaemon()
        let restarted = pairedDaemon(pid: 43, startedAt: "later")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)

        client.gate = .ready(restarted)
        let refreshed = await model.refreshAvailability()
        XCTAssertTrue(refreshed)
        client.resumeLaunch(id: "session-a")
        await send.value

        XCTAssertEqual(model.availability, .ready(restarted))
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        XCTAssertTrue(client.killPairings.isEmpty)
        XCTAssertFalse(model.hasPendingCleanup)
        XCTAssertNil(model.session)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertTrue(model.canRetry)
    }

    func testNewerReadyGenerationSupersedesLaunchForSameDaemonInstance() async {
        let pairingA = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)
        let requestGeneration = model.availabilityGeneration
        let trafficEpoch = model.trafficEpoch

        let refreshed = await model.refreshAvailability()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.availabilityGeneration, requestGeneration + 1)
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)
        client.resumeLaunch(id: "session-a")
        await send.value

        XCTAssertEqual(model.availability, .ready(pairingA))
        XCTAssertEqual(client.killedSessionIDs, ["session-a"])
        XCTAssertEqual(client.killPairings, [pairingA])
        XCTAssertNil(model.session)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertTrue(model.canRetry)
    }

    func testBlockedAvailabilitySupersedesSuspendedLaunch() async {
        let pairingA = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)
        let blocked = CompanionChatModel.Availability.blocked(
            reason: "Unavailable",
            hint: "Reconnect."
        )

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)

        client.gate = .blocked(reason: "Unavailable", hint: "Reconnect.")
        let refreshed = await model.refreshAvailability()
        XCTAssertTrue(refreshed)
        client.resumeLaunch(id: "session-a")
        await send.value

        XCTAssertEqual(model.availability, blocked)
        XCTAssertEqual(client.killedSessionIDs, ["session-a"])
        XCTAssertEqual(client.killPairings, [pairingA])
        XCTAssertNil(model.session)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertTrue(model.canRetry)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
    }

    func testUnpairedAvailabilitySupersedesSuspendedLaunch() async {
        let pairingA = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)

        client.gate = .notPaired
        let refreshed = await model.refreshAvailability()
        XCTAssertTrue(refreshed)
        client.resumeLaunch(id: "session-a")
        await send.value

        XCTAssertEqual(
            model.availability,
            .blocked(
                reason: "Not paired",
                hint: "Pair with a daemon in the Companion tab first."
            )
        )
        XCTAssertEqual(client.killedSessionIDs, ["session-a"])
        XCTAssertEqual(client.killPairings, [pairingA])
        XCTAssertNil(model.session)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertTrue(model.canRetry)
        XCTAssertFalse(model.items.contains { $0.kind == .error })
    }

    func testCheckingAvailabilitySupersedesSuspendedLaunch() async {
        let pairingA = pairedDaemon()
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)
        let requestGeneration = model.availabilityGeneration
        let trafficEpoch = model.trafficEpoch

        client.suspendsGate = true
        let refresh = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        XCTAssertEqual(model.availability, .checking)
        XCTAssertEqual(model.availabilityGeneration, requestGeneration + 1)
        XCTAssertEqual(model.trafficEpoch, trafficEpoch)

        client.resumeLaunch(id: "session-a")
        await send.value

        XCTAssertEqual(model.availability, .checking)
        XCTAssertEqual(client.killedSessionIDs, ["session-a"])
        XCTAssertEqual(client.killPairings, [pairingA])
        XCTAssertNil(model.session)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertTrue(model.canRetry)

        client.resumeNextGate(with: .ready(pairingB))
        let refreshed = await refresh.value
        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.availability, .ready(pairingB))
        XCTAssertEqual(model.trafficEpoch, trafficEpoch + 1)
    }

    func testNewerCheckingBeforeGateResponsePreventsLaunchSideEffect() async {
        let pairingA = pairedDaemon()
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        let model = CompanionChatModel(client: client)
        client.beforeGateResponse = {
            _ = model.beginAvailabilityCheck()
        }

        await model.send(prompt: "first", projectRoot: "/srv/repo")

        XCTAssertEqual(model.availability, .checking)
        XCTAssertTrue(client.launchedPrompts.isEmpty)
        XCTAssertNil(model.session)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.canRetry)

        client.gate = .ready(pairingB)
        let refreshed = await model.refreshAvailability()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.availability, .ready(pairingB))
    }

    func testUnchangedPairingTokenAdoptsSuspendedLaunchNormally() async {
        let pairingA = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        client.suspendsLaunch = true
        let model = CompanionChatModel(client: client)

        let send = Task {
            await model.send(prompt: "first", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.launchRequested], timeout: 1)

        client.resumeLaunch(id: "session-a")
        await send.value

        XCTAssertEqual(model.session?.id, "session-a")
        XCTAssertEqual(model.pairing, pairingA)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canRetry)
        await model.reset()
    }

    func testSendInputResponseFromSupersededPairingRetriesOnOriginalDaemon() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        client.suspendsSendInput = true

        let send = Task {
            await model.send(prompt: "second", projectRoot: "/srv/repo")
        }
        await fulfillment(of: [client.sendInputRequested], timeout: 1)

        client.gate = .ready(pairingB)
        let refreshed = await model.refreshAvailability()
        XCTAssertTrue(refreshed)
        client.resumeSendInput()
        await send.value

        XCTAssertEqual(client.sentInputs, ["second"])
        XCTAssertEqual(client.sentInputPairings, [pairingA])
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertEqual(client.killPairings, [pairingA])
        XCTAssertEqual(model.availability, .ready(pairingB))
        XCTAssertNil(model.session)
        XCTAssertNil(model.pairing)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.retryPrompt, "second")
        XCTAssertFalse(model.items.contains { $0.kind == .error })

        await model.retry()

        XCTAssertEqual(client.launchedPairings, [pairingA])
        XCTAssertEqual(model.retryPrompt, "second")
        XCTAssertTrue(model.canRetry)

        client.gate = .ready(pairingA)
        await model.retry()

        XCTAssertEqual(client.launchedPairings, [pairingA, pairingA])
        XCTAssertEqual(model.pairing, pairingA)
        XCTAssertNotNil(model.session)
        XCTAssertTrue(model.hasActivePollTask)
        await model.reset()
    }

    func testNewerCheckingBeforeGateResponsePreventsInputAndKeepsActiveSession() async {
        let pairingA = pairedDaemon()
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        completeTurn(on: model)
        client.beforeGateResponse = {
            _ = model.beginAvailabilityCheck()
        }

        await model.send(prompt: "second", projectRoot: "/srv/repo")

        XCTAssertEqual(model.availability, .checking)
        XCTAssertTrue(client.sentInputs.isEmpty)
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
        XCTAssertTrue(client.killPairings.isEmpty)
        XCTAssertEqual(model.session?.id, "session-1")
        XCTAssertEqual(model.pairing, pairingA)
        XCTAssertTrue(model.hasActivePollTask)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.retryPrompt, "second")
        XCTAssertFalse(model.items.contains { $0.kind == .error })
        await model.reset()
    }

    func testNewerReadySupersedesPollingRetryGateAndCleansPinnedSession() async {
        let pairingA = pairedDaemon(host: "a.tailnet.ts.net")
        let pairingB = pairedDaemon(host: "b.tailnet.ts.net")
        let client = FakeCompanionSessionClient(gate: .ready(pairingA))
        let model = CompanionChatModel(client: client)
        await model.send(prompt: "first", projectRoot: "/srv/repo")
        model.pollTask?.cancel()
        model.pollTask = nil
        client.eventError = .polling
        await model.refreshOnce()
        let errorCount = model.items.count { $0.kind == .error }
        client.eventError = nil
        client.suspendsGate = true

        let retry = Task { await model.retry() }
        await fulfillment(of: [client.gateRequested], timeout: 1)
        let refresh = Task { await model.refreshAvailability() }
        await fulfillment(of: [client.secondGateRequested], timeout: 1)

        client.resumeLastGate(with: .ready(pairingB))
        let refreshed = await refresh.value
        XCTAssertTrue(refreshed)
        client.resumeNextGate(with: .ready(pairingA))
        await retry.value

        XCTAssertEqual(model.availability, .ready(pairingB))
        XCTAssertEqual(client.killedSessionIDs, ["session-1"])
        XCTAssertEqual(client.killPairings, [pairingA])
        XCTAssertNil(model.session)
        XCTAssertNil(model.pairing)
        XCTAssertFalse(model.hasActivePollTask)
        XCTAssertEqual(model.items.count { $0.kind == .error }, errorCount)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.retriesPolling)
        XCTAssertFalse(model.canRetry)
    }
}
