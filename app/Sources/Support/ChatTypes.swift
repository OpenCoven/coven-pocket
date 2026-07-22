import Foundation

/// Settings a chat session is bound to. Changing any of them requires a new
/// engine session (the transcript restarts).
struct ChatSettings: Equatable {
    var provider: PocketProvider = .anthropic
    var apiKey: String = ""
    var model: String = ""
    var effort: String = "medium"
}

/// Answer sink for one approval request. `ChatPermissionResponder` conforms;
/// tests substitute a fake.
protocol ApprovalResponding {
    func respond(decision: ChatPermissionDecision)
}

extension ChatPermissionResponder: ApprovalResponding {}

/// An engine approval request awaiting the user's decision. Dropping it
/// without responding denies the tool call on the Rust side.
struct PendingApproval: Identifiable {
    let request: ChatPermissionRequest
    let responder: any ApprovalResponding

    var id: UInt64 { request.requestId }
}

extension ChatSessionSummary: Identifiable {
    /// Shared: `ISO8601DateFormatter` is thread-safe and costly to build
    /// per row.
    private static let rfc3339 = ISO8601DateFormatter()

    public var id: String { sessionId }

    /// Row title with a fallback for sessions that never got one.
    var displayTitle: String {
        title.isEmpty ? "Untitled session" : title
    }

    /// Parsed `updated_at`. The store writes chrono's `to_rfc3339`, whose
    /// variable-precision fraction `ISO8601DateFormatter` rejects — strip it.
    var updatedDate: Date? {
        let stripped = updatedAt.replacingOccurrences(
            of: #"\.\d+"#,
            with: "",
            options: .regularExpression
        )
        return Self.rfc3339.date(from: stripped)
    }
}

extension ChatPermissionMode {
    static let all: [ChatPermissionMode] = [.default, .acceptEdits, .plan]

    /// Stable string for UserDefaults persistence.
    var storageValue: String {
        switch self {
        case .default: return "default"
        case .acceptEdits: return "accept-edits"
        case .plan: return "plan"
        }
    }

    init(storageValue: String?) {
        switch storageValue {
        case ChatPermissionMode.acceptEdits.storageValue: self = .acceptEdits
        case ChatPermissionMode.plan.storageValue: self = .plan
        default: self = .default
        }
    }

    var label: String {
        switch self {
        case .default: return "Ask to edit"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan (read-only)"
        }
    }

    var symbolName: String {
        switch self {
        case .default: return "shield.lefthalf.filled"
        case .acceptEdits: return "checkmark.shield"
        case .plan: return "lock.shield"
        }
    }
}
