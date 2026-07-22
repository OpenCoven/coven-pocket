import Foundation

/// App-wide navigation state: which tab is showing, plus one-shot requests
/// handed in from outside SwiftUI (App Intents, Spotlight continuation).
/// Requests are consumed exactly once by the owning view; re-renders must
/// not replay them.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Tab: String, Hashable, CaseIterable {
        case chat, repos, companion, diff, playground

        var label: String {
            switch self {
            case .chat: return "Chat"
            case .repos: return "Repos"
            case .companion: return "Companion"
            case .diff: return "Diff"
            case .playground: return "Playground"
            }
        }

        var systemImage: String {
            switch self {
            case .chat: return "bubble.left.and.bubble.right"
            case .repos: return "arrow.triangle.branch"
            case .companion: return "antenna.radiowaves.left.and.right"
            case .diff: return "plus.forwardslash.minus"
            case .playground: return "testtube.2"
            }
        }

        /// Cmd+1…Cmd+5 section switching; nil for out-of-range digits.
        static func forShortcut(_ digit: Int) -> Tab? {
            let all = Tab.allCases
            guard digit >= 1, digit <= all.count else { return nil }
            return all[digit - 1]
        }
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
