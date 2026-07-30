import Foundation

// swiftlint:disable file_length

struct CompanionFamiliarPresentationContext: Equatable {
    let familiar: FamiliarIdentity?
    let profile: FamiliarProfileKey?

    static let empty = CompanionFamiliarPresentationContext(
        familiar: nil,
        profile: nil
    )
}

struct CompanionSendContext: Equatable {
    let prompt: String
    let projectRoot: String
    let familiarID: String?
    let familiarPresentation: CompanionFamiliarPresentationContext
}

struct CompanionCleanupOwnership {
    let sessionID: String
    let generation: UInt64
    let token: UInt64
    var waiters: [CheckedContinuation<Bool, Never>] = []
}

@MainActor
final class CompanionChatModel: ObservableObject {
    enum Availability: Equatable {
        case idle
        case checking
        case ready(DaemonPairing)
        case blocked(reason: String, hint: String)
    }

    @Published var items: [ChatItem] = []
    @Published var isBusy = false
    @Published var canRetry = false
    @Published var availability: Availability = .idle {
        didSet {
            if let terminal = availability.terminal {
                lastTerminalAvailability = terminal
            }
        }
    }
    @Published private var pinnedSessionFamiliar: FamiliarIdentity?

    var cursor: Int64 = 0

    static let requestTimeoutMs: UInt32 = 6_000
    static let pageLimit: UInt32 = 200
    static let pollInterval: Duration = .seconds(2)

    let companion: CompanionModel
    let client: any CompanionSessionClient
    var pairing: DaemonPairing?
    var sessionVerifiedPairing: VerifiedPairing?
    var session: RemoteSession?
    var sessionProjectRoot: String?
    var sessionFamiliarID: String?
    var accumulatedEvents: [RemoteEvent] = []
    var retryPrompt: String?
    var retryProjectRoot = ""
    var retryFamiliarID: String?
    var retryFamiliarPresentation = CompanionFamiliarPresentationContext.empty
    var pollTask: Task<Void, Never>?
    var lastCompletedResultSeq: Int64 = 0
    var initialPrompt: String?
    var initialPromptID: String?
    var retriesPolling = false
    var operationGeneration: UInt64 = 0
    var availabilityGeneration: UInt64 = 0
    private(set) var lastTerminalAvailability: Availability?
    var launchInFlight = false
    var pendingCleanup: RemoteSession?
    var pendingCleanupPairing: DaemonPairing?
    var pendingCleanupCompletionText: String?
    var cleanupOwnership: CompanionCleanupOwnership?
    var nextCleanupOwnershipToken: UInt64 = 0

    convenience init() {
        self.init(companion: CompanionModel())
    }

    convenience init(companion: CompanionModel) {
        self.init(
            companion: companion,
            client: LiveCompanionSessionClient(companion: companion)
        )
    }

    convenience init(client: any CompanionSessionClient) {
        self.init(companion: CompanionModel(), client: client)
    }

    init(
        companion: CompanionModel,
        client: any CompanionSessionClient
    ) {
        self.companion = companion
        self.client = client
    }

    var isAvailable: Bool {
        if case .ready = availability { return true }
        return false
    }

    var activeSessionFamiliarID: String? {
        sessionFamiliarID
    }

    var sessionFamiliar: FamiliarIdentity? {
        pinnedSessionFamiliar
    }

    var hasActiveSession: Bool {
        session != nil
    }

    var hasPendingCleanup: Bool {
        pendingCleanup != nil
    }

    var hasActivePollTask: Bool {
        pollTask != nil
    }

    @discardableResult
    func refreshAvailability() async -> Bool {
        guard !Task.isCancelled else { return false }
        return await availabilityGate(while: { true }) != nil
    }

    func beginAvailabilityCheck() -> UInt64 {
        availabilityGeneration &+= 1
        availability = .checking
        return availabilityGeneration
    }

    func availabilityGate(
        while isOperationCurrent: () -> Bool
    ) async -> (
        gate: CompanionModel.SessionGate,
        availabilityGeneration: UInt64
    )? {
        let previousTerminal = lastTerminalAvailability
        let generation = beginAvailabilityCheck()
        var publishedTerminal = false
        defer {
            completeAvailabilityCheck(
                generation: generation,
                publishedTerminal: publishedTerminal
            )
        }
        return await withTaskCancellationHandler {
            guard isOperationCurrent(), !Task.isCancelled else { return nil }
            let gate = await client.sessionGate()
            guard generation == availabilityGeneration,
                  isOperationCurrent(),
                  !Task.isCancelled else { return nil }
            availability = Self.availability(from: gate)
            publishedTerminal = true
            guard generation == availabilityGeneration,
                  isOperationCurrent(),
                  !Task.isCancelled else {
                if case .ready = gate { return nil }
                restoreAvailability(
                    for: generation,
                    to: previousTerminal
                )
                return nil
            }
            return (gate, generation)
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.restoreAvailability(for: generation)
            }
        }
    }

    private func completeAvailabilityCheck(
        generation: UInt64,
        publishedTerminal: Bool
    ) {
        guard !publishedTerminal else { return }
        restoreAvailability(for: generation)
    }

    private func restoreAvailability(for generation: UInt64) {
        guard generation == availabilityGeneration else { return }
        availability = lastTerminalAvailability ?? .idle
    }

    private func restoreAvailability(
        for generation: UInt64,
        to terminal: Availability?
    ) {
        guard generation == availabilityGeneration else { return }
        lastTerminalAvailability = terminal
        availability = terminal ?? .idle
    }

    // swiftlint:disable:next function_body_length
    func send(
        prompt: String,
        projectRoot: String,
        familiarID: String? = nil,
        familiar: FamiliarIdentity? = nil,
        familiarProfile: FamiliarProfileKey? = nil
    ) async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFamiliarID = Self.normalizedFamiliarID(familiarID)
        let presentation = CompanionFamiliarPresentationContext(
            familiar: familiar,
            profile: familiarProfile
        )
        let context = CompanionSendContext(
            prompt: trimmedPrompt,
            projectRoot: trimmedRoot,
            familiarID: normalizedFamiliarID,
            familiarPresentation: presentation
        )
        guard !Task.isCancelled,
              !trimmedPrompt.isEmpty,
              !isBusy,
              pendingCleanup == nil else { return }
        guard Self.isAbsoluteHostPath(trimmedRoot) else {
            retryFamiliarID = nil
            retryFamiliarPresentation = .empty
            fail(
                "Enter an absolute project path on the daemon host.",
                retryPrompt: nil
            )
            return
        }
        operationGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        let generation = operationGeneration
        isBusy = true
        retryProjectRoot = trimmedRoot
        retryFamiliarID = normalizedFamiliarID
        retryFamiliarPresentation = presentation
        guard !Task.isCancelled else {
            finishCancelledSend(generation: generation)
            return
        }
        guard let verified = await verifiedPairing(
            reportFailure: true,
            generation: generation
        ) else {
            await finishUnverifiedSend(
                context: context,
                generation: generation
            )
            return
        }
        guard canPerformSessionTraffic(
            pairing: verified,
            generation: generation
        ) else {
            if generation == operationGeneration, !Task.isCancelled {
                settleSupersededSend(
                    context: context,
                    generation: generation
                )
            } else {
                finishCancelledSend(generation: generation)
            }
            return
        }

        canRetry = false
        retryPrompt = nil
        retryFamiliarID = nil
        retryFamiliarPresentation = .empty
        retriesPolling = false
        do {
            try await performSend(
                context: context,
                pairing: verified,
                generation: generation
            )
        } catch {
            handleSendFailure(
                error,
                context: context,
                pairing: verified,
                generation: generation
            )
        }
        if Task.isCancelled {
            finishCancelledSend(generation: generation)
        }
    }
}

private extension CompanionChatModel.Availability {
    var terminal: Self? {
        switch self {
        case .idle, .checking:
            return nil
        case .ready, .blocked:
            return self
        }
    }
}

extension CompanionChatModel {
    func retry() async {
        guard !isBusy else { return }
        if pendingCleanup != nil {
            let prompt = retryPrompt
            let projectRoot = retryProjectRoot
            let familiarID = retryFamiliarID
            let familiarPresentation = retryFamiliarPresentation
            operationGeneration &+= 1
            let generation = operationGeneration
            pollTask?.cancel()
            pollTask = nil
            await retryPendingCleanup()
            guard generation == operationGeneration,
                  pendingCleanup == nil,
                  let prompt else { return }
            retryPrompt = nil
            retryFamiliarID = nil
            retryFamiliarPresentation = .empty
            await send(
                prompt: prompt,
                projectRoot: projectRoot,
                familiarID: familiarID,
                familiar: familiarPresentation.familiar,
                familiarProfile: familiarPresentation.profile
            )
            return
        }
        if retriesPolling {
            await retryPolling()
            return
        }
        guard let prompt = retryPrompt else { return }
        let familiarID = retryFamiliarID
        let familiarPresentation = retryFamiliarPresentation
        retryPrompt = nil
        retryFamiliarID = nil
        retryFamiliarPresentation = .empty
        await send(
            prompt: prompt,
            projectRoot: retryProjectRoot,
            familiarID: familiarID,
            familiar: familiarPresentation.familiar,
            familiarProfile: familiarPresentation.profile
        )
    }

    func finishInvalidatedPollingRetryIfNeeded(
        generation: UInt64
    ) -> Bool {
        guard generation != operationGeneration
                || Task.isCancelled else { return false }
        guard generation == operationGeneration else { return true }
        let shouldRetryPolling = isBusy || retriesPolling
        pollTask?.cancel()
        pollTask = nil
        isBusy = false
        guard shouldRetryPolling, session != nil, pairing != nil else {
            retriesPolling = false
            canRetry = pendingCleanup != nil
            return true
        }
        retriesPolling = true
        canRetry = true
        return true
    }

    func apply(events: [RemoteEvent]) {
        accumulatedEvents = events
        cursor = max(cursor, events.map(\.seq).max() ?? cursor)
        let snapshot = RemoteTranscript.snapshot(
            from: events,
            resultSemantics: .turn
        )
        items = Self.chatItems(from: snapshot.items)
        if let initialPrompt {
            items.insert(
                ChatItem(
                    id: initialPromptID ?? "companion-initial",
                    kind: .user,
                    text: initialPrompt
                ),
                at: 0
            )
        }

        if let newestResult = snapshot.latestResultSeq,
           newestResult > lastCompletedResultSeq {
            lastCompletedResultSeq = newestResult
            isBusy = false
        }
        if snapshot.sessionEnded {
            isBusy = false
            abandonSession()
        }
    }

    func stop() async {
        operationGeneration &+= 1
        let sessionToKill = session
        let pairingToKill = pairing
        pollTask?.cancel()
        pollTask = nil
        clearSessionBinding()
        canRetry = false
        retriesPolling = false
        retryPrompt = nil
        retryFamiliarID = nil
        retryFamiliarPresentation = .empty

        if let sessionToKill {
            await beginCleanup(
                of: sessionToKill,
                pairing: pairingToKill,
                completionText: "Stopped."
            )
        } else if pendingCleanup != nil {
            await retryPendingCleanup()
        } else if launchInFlight {
            isBusy = true
        } else {
            isBusy = false
            items.append(ChatItem(kind: .status, text: "Stopped."))
        }
    }

    func reset() async {
        operationGeneration &+= 1
        let sessionToKill = session
        let pairingToKill = pairing
        pollTask?.cancel()
        pollTask = nil
        pairing = nil
        clearSessionBinding()
        accumulatedEvents = []
        cursor = 0
        lastCompletedResultSeq = 0
        initialPrompt = nil
        initialPromptID = nil
        retriesPolling = false
        retryPrompt = nil
        retryProjectRoot = ""
        retryFamiliarID = nil
        retryFamiliarPresentation = .empty
        items = []
        canRetry = false
        pendingCleanupCompletionText = nil

        if let sessionToKill {
            await beginCleanup(
                of: sessionToKill,
                pairing: pairingToKill,
                completionText: nil
            )
        } else if pendingCleanup != nil {
            await retryPendingCleanup()
        } else {
            isBusy = launchInFlight
        }
    }

    func pinSessionFamiliar(
        id familiarID: String?,
        presentation: CompanionFamiliarPresentationContext,
        pairing: DaemonPairing
    ) {
        sessionFamiliarID = familiarID
        pinnedSessionFamiliar = Self.validatedSessionFamiliar(
            id: familiarID,
            presentation: presentation,
            pairing: pairing
        )
    }

    func clearSessionBinding() {
        session = nil
        sessionVerifiedPairing = nil
        sessionProjectRoot = nil
        sessionFamiliarID = nil
        pinnedSessionFamiliar = nil
    }

    static func validatedSessionFamiliar(
        id familiarID: String?,
        presentation: CompanionFamiliarPresentationContext,
        pairing: DaemonPairing
    ) -> FamiliarIdentity? {
        guard let familiarID else { return nil }
        let fallback = FamiliarIdentity(
            id: familiarID,
            displayName: familiarID,
            emoji: nil,
            role: nil
        )
        guard let familiar = presentation.familiar,
              familiar.id.caseInsensitiveCompare(familiarID) == .orderedSame,
              presentation.profile?.normalized == .companion(pairing: pairing)
        else {
            return fallback
        }
        return familiar
    }
}

// swiftlint:enable file_length
