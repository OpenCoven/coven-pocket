import Foundation

/// Connection settings and reachability state for a remote Coven daemon.
///
/// MVP transport: the daemon's TCP listener stays loopback on its own host;
/// the phone reaches it through the user's Tailscale network or an SSH
/// tunnel. This model owns the host/port config and the probe lifecycle.
@MainActor
final class CompanionModel: ObservableObject {
    enum ProbeStatus: Equatable {
        case idle
        case probing
        case reachable(pid: UInt32, latencyMs: UInt32)
        case failed(reason: String, hint: String)
    }

    @Published var host: String {
        didSet { defaults.set(host, forKey: Self.hostKey) }
    }
    @Published var portText: String {
        didSet { defaults.set(portText, forKey: Self.portKey) }
    }
    @Published private(set) var status: ProbeStatus = .idle

    let engine = PocketEngine()

    private let defaults: UserDefaults

    static let hostKey = "daemon-host"
    static let portKey = "daemon-port"
    static let defaultPort: UInt16 = 7777
    static let probeTimeoutMs: UInt32 = 4000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        host = defaults.string(forKey: Self.hostKey) ?? ""
        portText = defaults.string(forKey: Self.portKey) ?? String(Self.defaultPort)
    }

    /// The configured port, when the text field holds a valid one.
    var port: UInt16? {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return nil
        }
        return value
    }

    var canProbe: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && port != nil && status != .probing
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
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            timeoutMs: Self.probeTimeoutMs
        )
        status = Self.status(from: result)
    }

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
}
