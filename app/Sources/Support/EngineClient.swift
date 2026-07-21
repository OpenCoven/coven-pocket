import Foundation

/// Bridges the Rust engine's streaming callbacks onto the main actor and
/// exposes observable state for SwiftUI.
@MainActor
final class EngineClient: ObservableObject {
    @Published var transcript: String = ""
    @Published var thinking: String = ""
    @Published var isStreaming = false
    @Published var errorMessage: String?
    @Published var models: [PocketModel] = []

    let engine = PocketEngine()

    var engineVersion: String { engine.engineVersion() }
    var defaultModel: String { engine.defaultModel() }

    func loadModels(apiKey: String) async {
        do {
            models = try await engine.listModels(apiKey: apiKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(apiKey: String, model: String, prompt: String) async {
        transcript = ""
        thinking = ""
        errorMessage = nil
        isStreaming = true
        defer { isStreaming = false }
        do {
            try await engine.streamPrompt(
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                delegate: StreamBridge(client: self)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Callbacks arrive on Rust worker threads; hop to the main actor.
/// The only mutable state is the ARC-managed weak reference, which is
/// thread-safe to read, so `@unchecked Sendable` holds.
private final class StreamBridge: StreamDelegate, @unchecked Sendable {
    weak var client: EngineClient?

    init(client: EngineClient) {
        self.client = client
    }

    func onText(text: String) {
        Task { @MainActor [client] in client?.transcript += text }
    }

    func onThinking(text: String) {
        Task { @MainActor [client] in client?.thinking += text }
    }

    func onDone(stopReason: String) {}

    func onError(message: String) {
        Task { @MainActor [client] in client?.errorMessage = message }
    }
}
