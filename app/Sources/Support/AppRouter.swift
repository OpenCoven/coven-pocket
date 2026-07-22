import Foundation

/// App-wide navigation state: which tab is showing, plus one-shot requests
/// handed in from outside SwiftUI (App Intents, Spotlight continuation).
/// Requests are consumed exactly once by the owning view; re-renders must
/// not replay them.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Tab: String, Hashable {
        case chat, repos, companion, diff, playground
    }

    @Published var selectedTab: Tab = .chat
    /// A prompt to run in the chat tab, set by `AskCovenIntent`.
    @Published private(set) var pendingPrompt: String?
    /// A stored session to resume, set by Spotlight continuation.
    @Published private(set) var pendingSessionID: String?
    /// When true the chat tab should discard the live conversation first.
    @Published private(set) var pendingReset = false

    /// Route to chat and queue a prompt (nil focuses the tab only).
    func openChat(prompt: String?) {
        selectedTab = .chat
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingPrompt = prompt
        }
    }

    /// Route to chat and start a fresh conversation.
    func startFreshChat() {
        selectedTab = .chat
        pendingReset = true
    }

    /// Route to chat and queue a stored-session resume.
    func openSession(id: String) {
        selectedTab = .chat
        pendingSessionID = id
    }

    func consumePrompt() -> String? {
        defer { pendingPrompt = nil }
        return pendingPrompt
    }

    func consumeSessionID() -> String? {
        defer { pendingSessionID = nil }
        return pendingSessionID
    }

    func consumeReset() -> Bool {
        defer { pendingReset = false }
        return pendingReset
    }
}
