import Combine
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

@MainActor
enum CodexAccountTransitionCoordinator {
    static func handle(
        from oldProfileID: String?,
        to newProfileID: String?,
        invalidateRoutes: () -> Void,
        resetOnDevice: () -> Void,
        synchronizeFamiliar: () -> Void
    ) {
        guard oldProfileID != newProfileID else { return }
        invalidateRoutes()
        resetOnDevice()
        synchronizeFamiliar()
    }
}

@MainActor
final class ChatSurfaceState: ObservableObject {
    @Published var settings: ChatSettings

    let model: ChatModel
    let companion: CompanionModel
    let companionModel: CompanionChatModel
    let familiarModel: FamiliarSelectionModel
    let routeCoordinator: ChatRouteGenerationCoordinator

    convenience init() {
        let sharedCompanion = CompanionModel()
        self.init(
            model: ChatModel(),
            companion: sharedCompanion,
            companionModel: CompanionChatModel(companion: sharedCompanion),
            familiarModel: FamiliarSelectionModel(companion: sharedCompanion),
            routeCoordinator: ChatRouteGenerationCoordinator(),
            settings: ChatSettings(
                daemonProjectRoot: UserDefaults.standard.string(
                    forKey: "daemon-chat-project-root"
                ) ?? ""
            )
        )
    }

    init(
        model: ChatModel,
        companion: CompanionModel,
        companionModel: CompanionChatModel,
        familiarModel: FamiliarSelectionModel,
        routeCoordinator: ChatRouteGenerationCoordinator,
        settings: ChatSettings
    ) {
        self.model = model
        self.companion = companion
        self.companionModel = companionModel
        self.familiarModel = familiarModel
        self.routeCoordinator = routeCoordinator
        self.settings = settings
    }

    func activeFamiliarProfile(
        codexProfileID: String?
    ) -> FamiliarProfileKey? {
        ChatFamiliarProfile.active(
            backend: settings.backend,
            codexProfileID: codexProfileID,
            companionAvailability: companionModel.availability,
            companionPairing: companionModel.configuredPairing,
            previous: familiarModel.activeProfile
        )
    }

    func synchronizeFamiliarProfile(codexProfileID: String?) {
        settings.familiarID = ChatFamiliarProfile.synchronize(
            activeFamiliarProfile(codexProfileID: codexProfileID),
            model: familiarModel
        )
    }

    func handleCodexAccountTransition(
        from oldProfileID: String?,
        to newProfileID: String?
    ) {
        CodexAccountTransitionCoordinator.handle(
            from: oldProfileID,
            to: newProfileID,
            invalidateRoutes: { routeCoordinator.invalidate() },
            resetOnDevice: { model.reset() },
            synchronizeFamiliar: {
                synchronizeFamiliarProfile(
                    codexProfileID: newProfileID
                )
            }
        )
    }
}

@MainActor
final class ChatRouteGenerationCoordinator: ObservableObject {
    struct Token: Equatable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var cancelResume: (() -> Void)?

    func begin() -> Token {
        advanceGeneration()
        return Token(generation: generation)
    }

    func invalidate() {
        advanceGeneration()
    }

    func isCurrent(_ token: Token) -> Bool {
        token.generation == generation
    }

    func prepareToResume(
        _ token: Token,
        cancelOnInvalidation: @escaping () -> Void
    ) -> Bool {
        guard isCurrent(token) else { return false }
        cancelResume = cancelOnInvalidation
        return true
    }

    func retire(_ token: Token) {
        guard isCurrent(token) else { return }
        cancelResume = nil
        generation &+= 1
    }

    private func advanceGeneration() {
        let cancellation = cancelResume
        cancelResume = nil
        generation &+= 1
        cancellation?()
    }
}

@MainActor
enum SpotlightSessionRouteRunner {
    static func run<Summary>(
        token: ChatRouteGenerationCoordinator.Token,
        coordinator: ChatRouteGenerationCoordinator,
        lookup: @escaping () async -> Summary?,
        cancelResume: @escaping () -> Void,
        resume: @escaping (Summary) async -> Void
    ) async {
        guard coordinator.isCurrent(token) else { return }
        guard let summary = await lookup() else {
            coordinator.retire(token)
            return
        }
        guard coordinator.isCurrent(token),
              coordinator.prepareToResume(
                token,
                cancelOnInvalidation: cancelResume
              ) else { return }
        await resume(summary)
        guard coordinator.isCurrent(token) else { return }
        coordinator.retire(token)
    }
}

enum ChatFamiliarProfile {
    static func active(
        backend: ChatBackend,
        codexProfileID: String?,
        companionAvailability: CompanionChatModel.Availability,
        companionPairing: DaemonPairing?,
        previous: FamiliarProfileKey?
    ) -> FamiliarProfileKey? {
        switch backend {
        case .codex:
            return codexProfileID.map(FamiliarProfileKey.codex(profileID:))
        case .companionClaude:
            guard let companionPairing else { return nil }
            switch companionAvailability {
            case let .ready(pairing):
                return .companion(pairing: pairing)
            case .checking:
                if case .companion = previous {
                    return previous?.normalized
                }
                return .companion(pairing: companionPairing)
            case .idle, .blocked:
                return .companion(pairing: companionPairing)
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
        if preserveCurrent, !profileChanged {
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
