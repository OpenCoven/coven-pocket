import XCTest
@testable import CovenPocket

/// An in-memory pairing store so tests never touch the real Keychain.
private final class InMemoryPairingStore: PairingStore {
    var stored: DaemonPairing?

    func load() -> DaemonPairing? { stored }
    func save(_ pairing: DaemonPairing) { stored = pairing }
    func clear() { stored = nil }
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
    private func makeModel(store: PairingStore) -> CompanionModel {
        let defaults = UserDefaults(suiteName: "pairing-tests-\(UUID().uuidString)")!
        return CompanionModel(defaults: defaults, store: store)
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
}
