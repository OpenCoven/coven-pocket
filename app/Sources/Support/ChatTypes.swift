import Foundation

enum ChatBackend: String, CaseIterable, Hashable {
    case companionClaude
    case codex

    static func available(
        companionAvailable: Bool,
        codexAvailable: Bool
    ) -> [ChatBackend] {
        var backends: [ChatBackend] = []
        if companionAvailable {
            backends.append(.companionClaude)
        }
        if codexAvailable {
            backends.append(.codex)
        }
        return backends
    }

    var label: String {
        switch self {
        case .companionClaude: return "Claude via Companion"
        case .codex: return "Codex"
        }
    }
}

/// Backend-specific settings for the Chat surface.
struct ChatSettings: Equatable {
    var backend: ChatBackend = .companionClaude
    var model: String = ""
    var daemonProjectRoot: String = ""
    var familiarID: String?
}

enum ChatFamiliarProfile {
    static func active(
        backend: ChatBackend,
        codexProfileID: String?,
        companionAvailability: CompanionChatModel.Availability,
        previous: FamiliarProfileKey?
    ) -> FamiliarProfileKey? {
        switch backend {
        case .codex:
            return codexProfileID.map(FamiliarProfileKey.codex(profileID:))
        case .companionClaude:
            switch companionAvailability {
            case let .ready(pairing):
                return .companion(pairing: pairing)
            case .checking:
                guard case .companion = previous else { return nil }
                return previous
            case .blocked:
                return nil
            }
        }
    }

    @MainActor
    static func synchronize(
        _ profile: FamiliarProfileKey?,
        model: FamiliarSelectionModel,
        currentFamiliarID: String? = nil,
        preserveCurrent: Bool = false
    ) -> String? {
        let profileChanged = model.activeProfile != profile?.normalized
        if profileChanged {
            model.activate(profile)
        }
        if preserveCurrent {
            return currentFamiliarID
        }
        return model.selectedFamiliar?.id
    }

    @MainActor
    static func settingsForCodexResume(
        current: ChatSettings,
        codexProfileID: String?,
        defaultModel: String,
        model: FamiliarSelectionModel
    ) -> ChatSettings? {
        guard let codexProfileID, !codexProfileID.isEmpty else {
            return nil
        }

        var prepared = current
        prepared.backend = .codex
        if prepared.model.isEmpty {
            prepared.model = defaultModel
        }
        prepared.familiarID = synchronize(
            .codex(profileID: codexProfileID),
            model: model
        )
        return prepared
    }
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
