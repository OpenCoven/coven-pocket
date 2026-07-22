import Foundation

/// A confirmed pairing with one daemon, persisted in the Keychain.
///
/// `pid`/`startedAt` describe the daemon instance seen at pairing time and
/// refresh on verify — restarts are expected. Identity confirmation is a
/// human step about the host, not a cryptographic pin; the transport
/// (Tailscale/SSH) owns wire security.
struct DaemonPairing: Codable, Equatable {
    var host: String
    var port: UInt16
    var apiVersion: String
    var covenVersion: String
    var pid: UInt32
    var startedAt: String
    var pairedAt: Date
}

/// Where pairings persist. Production uses the Keychain; tests inject memory.
protocol PairingStore {
    func load() -> DaemonPairing?
    func save(_ pairing: DaemonPairing)
    func clear()
}

struct KeychainPairingStore: PairingStore {
    static let key = "daemon-pairing"

    func load() -> DaemonPairing? {
        guard let raw = Keychain.get(Self.key), let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? DaemonPairing.decoder.decode(DaemonPairing.self, from: data)
    }

    func save(_ pairing: DaemonPairing) {
        guard let data = try? DaemonPairing.encoder.encode(pairing),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        Keychain.set(raw, for: Self.key)
    }

    func clear() {
        Keychain.delete(Self.key)
    }
}

extension DaemonPairing {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Connection settings, reachability state, and pairing lifecycle for a
/// remote Coven daemon.
///
/// MVP transport: the daemon's TCP listener stays loopback on its own host;
/// the phone reaches it through the user's Tailscale network or an SSH
/// tunnel. Pairing requires the `coven.daemon.v1` handshake to succeed and
/// gates all future session traffic through `gateForSessionTraffic()`.
@MainActor
final class CompanionModel: ObservableObject {
    enum ProbeStatus: Equatable {
        case idle
        case probing
        case reachable(pid: UInt32, latencyMs: UInt32)
        case verified
        case failed(reason: String, hint: String)
    }

    /// Mandatory gate for remote-session features: obtain `.ready` before
    /// opening any session traffic.
    enum SessionGate: Equatable {
        case ready(DaemonPairing)
        case notPaired
        case blocked(reason: String, hint: String)
    }

    @Published var host: String {
        didSet { defaults.set(host, forKey: Self.hostKey) }
    }
    @Published var portText: String {
        didSet { defaults.set(portText, forKey: Self.portKey) }
    }
    @Published private(set) var status: ProbeStatus = .idle
    @Published private(set) var pairing: DaemonPairing?
    /// Set when a handshake succeeded and the user must confirm identity.
    @Published private(set) var pendingIdentity: DaemonIdentity?

    let engine = PocketEngine()

    private let defaults: UserDefaults
    private let store: PairingStore

    static let hostKey = "daemon-host"
    static let portKey = "daemon-port"
    static let defaultPort: UInt16 = 7777
    static let probeTimeoutMs: UInt32 = 4000

    init(defaults: UserDefaults = .standard, store: PairingStore = KeychainPairingStore()) {
        self.defaults = defaults
        self.store = store
        host = defaults.string(forKey: Self.hostKey) ?? ""
        portText = defaults.string(forKey: Self.portKey) ?? String(Self.defaultPort)
        pairing = store.load()
    }

    /// The configured port, when the text field holds a valid one.
    var port: UInt16? {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return nil
        }
        return value
    }

    var trimmedHost: String {
        host.trimmingCharacters(in: .whitespaces)
    }

    var canProbe: Bool {
        !trimmedHost.isEmpty && port != nil && status != .probing
    }

    func probe() async {
        guard let port else {
            status = .failed(
                reason: "Invalid port",
                hint: "Enter a port between 1 and 65535."
            )
            return
        }
        status = .probing
        let result = await engine.probeDaemon(
            host: trimmedHost,
            port: port,
            timeoutMs: Self.probeTimeoutMs
        )
        status = Self.status(from: result)
    }

    // MARK: - Pairing lifecycle

    /// Run the `coven.daemon.v1` handshake; on success, stage the daemon's
    /// identity for the user to confirm.
    func beginPairing() async {
        guard let port else {
            status = .failed(reason: "Invalid port", hint: "Enter a port between 1 and 65535.")
            return
        }
        status = .probing
        let result = await engine.handshakeDaemon(
            host: trimmedHost,
            port: port,
            timeoutMs: Self.probeTimeoutMs
        )
        if case let .compatible(identity, _) = result {
            status = .idle
            stage(identity: identity)
        } else {
            status = Self.pairingStatus(from: result)
        }
    }

    /// Stage a handshake-verified identity for confirmation. Split from
    /// `beginPairing()` so tests can drive the confirm flow without a network.
    func stage(identity: DaemonIdentity) {
        pendingIdentity = identity
    }

    func confirmPairing() {
        guard let identity = pendingIdentity, let port else { return }
        let confirmed = DaemonPairing(
            host: trimmedHost,
            port: port,
            apiVersion: identity.apiVersion,
            covenVersion: identity.covenVersion,
            pid: identity.pid,
            startedAt: identity.startedAt,
            pairedAt: Date()
        )
        store.save(confirmed)
        pairing = confirmed
        pendingIdentity = nil
        status = .idle
    }

    func cancelPairing() {
        pendingIdentity = nil
    }

    func unpair() {
        store.clear()
        pairing = nil
        status = .idle
    }

    /// Re-run the handshake against the stored pairing and surface the result.
    func verifyPairing() async {
        status = .probing
        switch await gateForSessionTraffic() {
        case .ready:
            status = .verified
        case .notPaired:
            status = .failed(reason: "Not paired", hint: "Pair with a daemon first.")
        case let .blocked(reason, hint):
            status = .failed(reason: reason, hint: hint)
        }
    }

    /// Enforce the handshake before session traffic: re-verify the stored
    /// pairing so a swapped or downgraded daemon cannot slip past it. The
    /// stored identity refreshes on success (daemon restarts are normal).
    func gateForSessionTraffic() async -> SessionGate {
        guard var current = pairing else { return .notPaired }
        let result = await engine.handshakeDaemon(
            host: current.host,
            port: current.port,
            timeoutMs: Self.probeTimeoutMs
        )
        switch result {
        case let .compatible(identity, _):
            current.covenVersion = identity.covenVersion
            current.pid = identity.pid
            current.startedAt = identity.startedAt
            store.save(current)
            pairing = current
            return .ready(current)
        default:
            guard case let .failed(reason, hint) = Self.pairingStatus(from: result) else {
                return .blocked(reason: "Pairing unavailable", hint: "Run Verify connection.")
            }
            return .blocked(reason: reason, hint: hint)
        }
    }

    // MARK: - Copy mapping

    /// Map an engine probe result onto UI copy. Static and pure for tests.
    static func status(from state: DaemonProbeState) -> ProbeStatus {
        switch state {
        case let .reachable(pid, _, latencyMs):
            return .reachable(pid: pid, latencyMs: latencyMs)
        case .refused:
            return .failed(
                reason: "Connection refused",
                hint: "Nothing is listening there. Check the tunnel is up and the "
                    + "daemon was started with --tcp on that port."
            )
        case .timedOut:
            return .failed(
                reason: "Timed out",
                hint: "No answer. Check the host address, that the device is on the "
                    + "same Tailscale network, or that the SSH tunnel is running."
            )
        case .unresolvable:
            return .failed(
                reason: "Host not found",
                hint: "The name did not resolve. Use the machine's Tailscale name, "
                    + "IP address, or localhost when tunneling."
            )
        case let .notADaemon(detail):
            return .failed(
                reason: "Not a Coven daemon",
                hint: detail
            )
        case let .failed(detail):
            return .failed(reason: "Connection failed", hint: detail)
        }
    }

    /// Map a handshake result onto UI copy. Transport failures share the
    /// probe copy; the version mismatch is the pairing-specific case.
    static func pairingStatus(from result: DaemonHandshake) -> ProbeStatus {
        switch result {
        case let .compatible(identity, latencyMs):
            return .reachable(pid: identity.pid, latencyMs: latencyMs)
        case let .versionMismatch(reported):
            return .failed(
                reason: "Protocol mismatch",
                hint: "This daemon offers \(reported), but Coven Pocket requires "
                    + "coven.daemon.v1. Update coven on the host "
                    + "(npm i -g @opencoven/cli) or update this app, then pair again."
            )
        case .refused:
            return status(from: .refused)
        case .timedOut:
            return status(from: .timedOut)
        case .unresolvable:
            return status(from: .unresolvable)
        case let .notADaemon(detail):
            return status(from: .notADaemon(detail: detail))
        case let .failed(detail):
            return status(from: .failed(detail: detail))
        }
    }
}
