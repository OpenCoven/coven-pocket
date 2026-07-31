import XCTest
@testable import CovenPocket

/// An in-memory pairing store so tests never touch the real Keychain.
private final class InMemoryPairingStore: PairingStore {
    var stored: DaemonPairing?

    func load() -> DaemonPairing? { stored }
    func save(_ pairing: DaemonPairing) { stored = pairing }
    func clear() { stored = nil }
}

@MainActor
private final class ControllableCompanionHandshake {
    private(set) var callCount = 0
    private var continuations: [
        CheckedContinuation<DaemonHandshake, Never>
    ] = []

    func call(
        host: String,
        port: UInt16,
        timeoutMs: UInt32
    ) async -> DaemonHandshake {
        callCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeAll(with result: DaemonHandshake) {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume(returning: result) }
    }
}

private func makeIdentity(pid: UInt32 = 31415) -> DaemonIdentity {
    DaemonIdentity(
        apiVersion: "coven.daemon.v1",
        covenVersion: "0.3.0",
        pid: pid,
        startedAt: "2026-05-15T19:31:02Z",
        sessions: true,
        events: true
    )
}

@MainActor
final class CompanionPairingTests: XCTestCase {
    func testConfirmPublishesPersistedPairingRepresentation() {
        final class RoundTripStore: PairingStore {
            var stored: DaemonPairing?

            func load() -> DaemonPairing? { stored }

            func save(_ pairing: DaemonPairing) {
                guard let data = try? DaemonPairing.encoder.encode(pairing) else {
                    return
                }
                stored = try? DaemonPairing.decoder.decode(DaemonPairing.self, from: data)
            }

            func clear() {
                stored = nil
            }
        }

        let store = RoundTripStore()
        let model = makeModel(store: store)
        model.stage(identity: makeIdentity())
        model.confirmPairing()

        XCTAssertEqual(model.pairing, store.stored)
    }

    private func makeModel(
        store: PairingStore,
        handshake: CompanionHandshake? = nil
    ) -> CompanionModel {
        let defaults = UserDefaults(suiteName: "pairing-tests-\(UUID().uuidString)")!
        return CompanionModel(
            defaults: defaults,
            store: store,
            handshake: handshake
        )
    }

    func testConfirmPairingPersistsTheStagedIdentity() throws {
        let store = InMemoryPairingStore()
        let model = makeModel(store: store)
        model.host = " mac.tailnet.ts.net "
        model.portText = "7777"

        model.stage(identity: makeIdentity())
        XCTAssertNotNil(model.pendingIdentity)
        model.confirmPairing()

        XCTAssertNil(model.pendingIdentity)
        let pairing = try XCTUnwrap(model.pairing)
        XCTAssertEqual(pairing.host, "mac.tailnet.ts.net")
        XCTAssertEqual(pairing.port, 7777)
        XCTAssertEqual(pairing.apiVersion, "coven.daemon.v1")
        XCTAssertEqual(pairing.covenVersion, "0.3.0")
        XCTAssertEqual(store.stored, model.pairing)
    }

    func testCancelPairingLeavesNothingPersisted() {
        let store = InMemoryPairingStore()
        let model = makeModel(store: store)
        model.host = "mac"
        model.stage(identity: makeIdentity())
        model.cancelPairing()

        XCTAssertNil(model.pendingIdentity)
        XCTAssertNil(model.pairing)
        XCTAssertNil(store.stored)
    }

    func testUnpairClearsStoreAndModel() {
        let store = InMemoryPairingStore()
        let model = makeModel(store: store)
        model.host = "mac"
        model.portText = "7777"
        model.stage(identity: makeIdentity())
        model.confirmPairing()
        XCTAssertNotNil(store.stored)

        model.unpair()
        XCTAssertNil(model.pairing)
        XCTAssertNil(store.stored)
    }

    func testPairingRestoresFromStoreOnLaunch() {
        let store = InMemoryPairingStore()
        store.stored = DaemonPairing(
            host: "mac", port: 7777,
            apiVersion: "coven.daemon.v1", covenVersion: "0.3.0",
            pid: 1, startedAt: "x", pairedAt: Date()
        )
        let model = makeModel(store: store)
        XCTAssertEqual(model.pairing?.host, "mac")
    }

    func testReloadPairingObservesAnotherModelsPairingChange() {
        let store = InMemoryPairingStore()
        let staleModel = makeModel(store: store)
        let pairing = DaemonPairing(
            host: "mac", port: 7777,
            apiVersion: "coven.daemon.v1", covenVersion: "0.3.0",
            pid: 1, startedAt: "x", pairedAt: Date()
        )
        store.stored = pairing

        staleModel.reloadPairing()

        XCTAssertEqual(staleModel.pairing, pairing)
    }

    func testPairingRoundTripsThroughKeychain() throws {
        let keychainStore = KeychainPairingStore()
        defer { keychainStore.clear() }
        let pairing = DaemonPairing(
            host: "mac.tailnet.ts.net", port: 7777,
            apiVersion: "coven.daemon.v1", covenVersion: "0.3.0",
            pid: 31415, startedAt: "2026-05-15T19:31:02Z",
            pairedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        keychainStore.save(pairing)
        let restored = try XCTUnwrap(keychainStore.load())
        XCTAssertEqual(restored, pairing)

        keychainStore.clear()
        XCTAssertNil(keychainStore.load())
    }

    func testVersionMismatchCopyNamesTheContract() {
        let status = CompanionModel.pairingStatus(
            from: .versionMismatch(reported: "coven.daemon.v2")
        )
        guard case let .failed(reason, hint) = status else {
            return XCTFail("expected failure copy")
        }
        XCTAssertEqual(reason, "Protocol mismatch")
        XCTAssertTrue(hint.contains("coven.daemon.v2"), "names what the daemon offered")
        XCTAssertTrue(hint.contains("coven.daemon.v1"), "names the required contract")
        XCTAssertTrue(hint.contains("Update coven"), "says what to do about it")
    }

    func testHandshakeTransportFailuresShareProbeCopy() {
        XCTAssertEqual(
            CompanionModel.pairingStatus(from: .refused),
            CompanionModel.status(from: .refused)
        )
        XCTAssertEqual(
            CompanionModel.pairingStatus(from: .timedOut),
            CompanionModel.status(from: .timedOut)
        )
        XCTAssertEqual(
            CompanionModel.pairingStatus(from: .unresolvable),
            CompanionModel.status(from: .unresolvable)
        )
    }

    func testSessionGateRequiresAPairing() async {
        let model = makeModel(store: InMemoryPairingStore())
        let gate = await model.gateForSessionTraffic()
        XCTAssertEqual(gate, .notPaired)
    }

    func testSessionGateBlocksWhenDaemonIsGone() async {
        // Paired against a local port with nothing listening: the gate must
        // re-run the handshake and block, not trust the stored pairing.
        let store = InMemoryPairingStore()
        store.stored = DaemonPairing(
            host: "127.0.0.1", port: 1,
            apiVersion: "coven.daemon.v1", covenVersion: "0.3.0",
            pid: 1, startedAt: "x", pairedAt: Date()
        )
        let model = makeModel(store: store)
        let gate = await model.gateForSessionTraffic()
        guard case .blocked = gate else {
            return XCTFail("expected blocked gate, got \(gate)")
        }
    }

    func testConcurrentSessionGatesDoNotSupersedeTheSamePairing() async {
        let store = InMemoryPairingStore()
        store.stored = DaemonPairing(
            host: "127.0.0.1", port: 1,
            apiVersion: "coven.daemon.v1", covenVersion: "0.3.0",
            pid: 1, startedAt: "x", pairedAt: Date()
        )
        let model = makeModel(store: store)

        let first = Task { await model.gateForSessionTraffic() }
        await Task.yield()
        let second = Task { await model.gateForSessionTraffic() }
        let results = await [first.value, second.value]

        for result in results {
            guard case let .blocked(reason, _) = result else {
                return XCTFail("expected blocked gate, got \(result)")
            }
            XCTAssertNotEqual(reason, "Pairing check superseded")
        }
    }

    func testUnchangedReloadJoinsConcurrentSessionGate() async {
        let pairing = DaemonPairing(
            host: "mac", port: 7777,
            apiVersion: "coven.daemon.v1", covenVersion: "0.3.0",
            pid: 1, startedAt: "x", pairedAt: Date()
        )
        let store = InMemoryPairingStore()
        store.stored = pairing
        let handshake = ControllableCompanionHandshake()
        let model = makeModel(
            store: store,
            handshake: handshake.call
        )

        let first = Task { await model.gateForSessionTraffic() }
        while handshake.callCount < 1 {
            await Task.yield()
        }
        model.reloadPairing()
        let second = Task { await model.gateForSessionTraffic() }
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(handshake.callCount, 1)
        handshake.resumeAll(with: .refused)
        let results = await [first.value, second.value]
        for result in results {
            guard case let .blocked(reason, _) = result else {
                return XCTFail("expected blocked gate, got \(result)")
            }
            XCTAssertNotEqual(reason, "Pairing check superseded")
        }
    }

    func testInvalidatedWaiterCannotReturnCompletedGateAuthority() async {
        let pairing = DaemonPairing(
            host: "mac", port: 7777,
            apiVersion: "coven.daemon.v1", covenVersion: "0.3.0",
            pid: 1, startedAt: "x", pairedAt: Date()
        )
        let store = InMemoryPairingStore()
        store.stored = pairing
        let handshake = ControllableCompanionHandshake()
        let model = makeModel(
            store: store,
            handshake: handshake.call
        )

        let staleWaiter = Task {
            await model.gateForSessionTraffic()
        }
        while handshake.callCount < 1 {
            await Task.yield()
        }
        let invalidatingWaiter = Task {
            let result = await model.gateForSessionTraffic()
            model.unpair()
            return result
        }
        handshake.resumeAll(
            with: .compatible(identity: makeIdentity(), latencyMs: 1)
        )

        guard case .ready = await invalidatingWaiter.value else {
            return XCTFail("the first waiter should receive ready authority")
        }
        let staleResult = await staleWaiter.value
        guard case let .blocked(reason, _) = staleResult else {
            return XCTFail("expected invalidated gate, got \(staleResult)")
        }
        XCTAssertEqual(reason, "Pairing check superseded")
    }
}
