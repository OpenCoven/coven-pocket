import Foundation

/// Chat callbacks arrive on Rust worker threads; hop to the main actor.
/// The only mutable state is the ARC-managed weak reference, which is
/// thread-safe to read, so `@unchecked Sendable` holds.
final class ChatBridge: ChatDelegate, @unchecked Sendable {
    weak var model: ChatModel?

    init(model: ChatModel) {
        self.model = model
    }

    func onText(text: String) {
        Task { @MainActor [model] in model?.appendAssistantText(text) }
    }

    func onThinking(text: String) {
        Task { @MainActor [model] in model?.appendThinking(text) }
    }

    func onToolStart(toolId: String, toolName: String, inputJson: String) {
        Task { @MainActor [model] in
            model?.beginTool(id: toolId, name: toolName, inputJson: inputJson)
        }
    }

    func onToolEnd(toolId: String, toolName: String, result: String, isError: Bool) {
        Task { @MainActor [model] in
            model?.endTool(id: toolId, result: result, isError: isError)
        }
    }

    func onStatus(message: String) {
        Task { @MainActor [model] in model?.appendStatus(message) }
    }

    func onPermissionRequest(request: ChatPermissionRequest, responder: ChatPermissionResponder) {
        Task { @MainActor [model] in
            // If the model is gone the approval drops here, which denies.
            model?.receiveApproval(PendingApproval(request: request, responder: responder))
        }
    }

    func onDone(stopReason: String) {
        Task { @MainActor [model] in model?.finishTurn(stopReason: stopReason) }
    }

    func onError(message: String) {
        Task { @MainActor [model] in model?.appendError(message) }
    }
}
