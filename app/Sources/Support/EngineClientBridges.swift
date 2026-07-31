import Foundation

/// Callbacks arrive on Rust worker threads; hop to the main actor.
/// The only mutable state is the ARC-managed weak reference, which is
/// thread-safe to read, so `@unchecked Sendable` holds.
final class StreamBridge: StreamDelegate, @unchecked Sendable {
    weak var client: EngineClient?
    let token: StreamOperationToken

    init(client: EngineClient, token: StreamOperationToken) {
        self.client = client
        self.token = token
    }

    func onText(text: String) {
        Task { @MainActor [client, token] in
            client?.appendText(text, for: token)
        }
    }

    func onThinking(text: String) {
        Task { @MainActor [client, token] in
            client?.appendThinking(text, for: token)
        }
    }

    func onDone(stopReason: String) {}

    func onError(message: String) {
        Task { @MainActor [client, token] in
            client?.publishStreamError(message, for: token)
        }
    }
}

/// Login-flow callbacks arrive on Rust worker threads; hop to the main actor.
/// Same `@unchecked Sendable` justification as `StreamBridge`.
final class AuthBridge: CodexAuthDelegate, @unchecked Sendable {
    weak var client: EngineClient?
    let generation: UInt64

    init(client: EngineClient, generation: UInt64) {
        self.client = client
        self.generation = generation
    }

    func onAuthUrl(url: String) {
        Task { @MainActor [client, generation] in
            client?.publishAuthURL(url, generation: generation)
        }
    }
}
