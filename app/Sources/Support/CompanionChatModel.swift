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

struct CompanionPromptRetrySelection: Equatable {
    let familiarID: String?
    let familiar: FamiliarIdentity?
    let profile: FamiliarProfileKey?

    static let empty = CompanionPromptRetrySelection(
        familiarID: nil,
        familiar: nil,
        profile: nil
    )
}

struct CompanionPromptRetryResolution {
    let context: CompanionSendContext
    let requiresSelectionFence: Bool
}

struct CompanionPromptRetryLaunchFence {
    let originalContext: CompanionSendContext
    let currentSelection: @MainActor () -> CompanionPromptRetrySelection
}

struct CompanionPreparedPromptRetry {
    let context: CompanionSendContext
    let launchFence: CompanionPromptRetryLaunchFence?
}

struct CompanionPreparedLaunch {
    let session: RemoteSession
    let context: CompanionSendContext
}

struct CompanionSendContext: Equatable {
    let prompt: String
    let projectRoot: String
    let familiarID: String?
    let familiarPresentation: CompanionFamiliarPresentationContext
    let targetProfile: FamiliarProfileKey?

    func bindingMissingProfiles(
        to pairing: DaemonPairing
    ) -> CompanionSendContext {
        let endpointProfile = FamiliarProfileKey.companion(pairing: pairing)
        let presentation: CompanionFamiliarPresentationContext
        if familiarID != nil, familiarPresentation.profile == nil {
            presentation = CompanionFamiliarPresentationContext(
                familiar: familiarPresentation.familiar,
                profile: endpointProfile
            )
        } else {
            presentation = familiarPresentation
        }
        return CompanionSendContext(
            prompt: prompt,
            projectRoot: projectRoot,
            familiarID: familiarID,
            familiarPresentation: presentation,
            targetProfile: targetProfile ?? endpointProfile
        )
    }

    func targets(_ pairing: DaemonPairing) -> Bool {
        targetProfile?.normalized
            == FamiliarProfileKey.companion(pairing: pairing)
    }
}

struct CompanionContextualSendError: LocalizedError {
    let underlying: Error
    let context: CompanionSendContext

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

struct CompanionCleanupOwnership {
    let sessionID: String
    let generation: UInt64
    let token: UInt64
    var waiters: [CheckedContinuation<Bool, Never>] = []
}

enum CompanionTrafficAuthority {
    case unavailable
    case ready(DaemonPairing)
}

enum CompanionPairingVerificationMode {
    case request
    case trafficEpoch
}

@MainActor
// swiftlint:disable:next type_body_length
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
    var retryTargetProfile: FamiliarProfileKey?
    var pollTask: Task<Void, Never>?
    var lastCompletedResultSeq: Int64 = 0
    var initialPrompt: String?
    var initialPromptID: String?
    var retriesPolling = false
    var operationGeneration: UInt64 = 0
    var availabilityGeneration: UInt64 = 0
    var trafficEpoch: UInt64 = 0
    var trafficAuthority: CompanionTrafficAuthority?
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

    var configuredPairing: DaemonPairing? {
        companion.pairing
    }

    var configuredFamiliarProfile: FamiliarProfileKey? {
        configuredPairing.map(FamiliarProfileKey.companion(pairing:))
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
            guard generation == availabilityGeneration,
                  isOperationCurrent() else {
                if case .ready = gate { return nil }
                restoreAvailability(
                    for: generation,
                    to: previousTerminal
                )
                return nil
            }
            if Task.isCancelled {
                if case .ready = gate, previousTerminal == nil {
                    publishedTerminal = true
                } else {
                    restoreAvailability(
                        for: generation,
                        to: previousTerminal
                    )
                }
                return nil
            }
            updateTrafficAuthority(for: availability)
            publishedTerminal = true
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
        familiarProfile: FamiliarProfileKey? = nil,
        targetProfile: FamiliarProfileKey? = nil,
        verificationMode: CompanionPairingVerificationMode = .request,
        expectedTrafficEpoch: UInt64? = nil,
        promptRetrySelection: (
            @MainActor () -> CompanionPromptRetrySelection
        )? = nil
    ) async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFamiliarID = Self.normalizedFamiliarID(familiarID)
        let presentation = CompanionFamiliarPresentationContext(
            familiar: familiar,
            profile: familiarProfile?.normalized
        )
        let context = CompanionSendContext(
            prompt: trimmedPrompt,
            projectRoot: trimmedRoot,
            familiarID: normalizedFamiliarID,
            familiarPresentation: presentation,
            targetProfile: targetProfile?.normalized
                ?? configuredFamiliarProfile?.normalized
        )
        guard !Task.isCancelled,
              !trimmedPrompt.isEmpty,
              !isBusy,
              pendingCleanup == nil else { return }
        guard Self.isAbsoluteHostPath(trimmedRoot) else {
            retryFamiliarID = nil
            retryFamiliarPresentation = .empty
            retryTargetProfile = nil
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
        let verification = CompanionOperationVerification(
            mode: verificationMode,
            expectedTrafficEpoch: expectedTrafficEpoch
        )
        guard let verified = await verifiedPairing(
            reportFailure: true,
            generation: generation,
            verificationMode: verificationMode
        ) else {
            await finishUnverifiedSend(
                context: context,
                generation: generation
            )
            return
        }
        var verifiedContext = context.bindingMissingProfiles(
            to: verified.pairing
        )
        let pairingIsCurrent = generation == operationGeneration
            && !Task.isCancelled
            && verification.isCurrent(verified, on: self)
        guard pairingIsCurrent else {
            if generation == operationGeneration, !Task.isCancelled {
                settleSupersededSend(
                    context: verifiedContext,
                    generation: generation
                )
            } else {
                finishCancelledSend(generation: generation)
            }
            return
        }
        let canExplicitlyRebindFamiliar = verifiedContext.familiarID != nil
            && promptRetrySelection != nil
        guard verifiedContext.targets(verified.pairing)
                || canExplicitlyRebindFamiliar else {
            rejectPromptRetryDestination(
                context: verifiedContext,
                generation: generation
            )
            return
        }
        guard let preparedRetry = preparePromptRetry(
            original: verifiedContext,
            currentSelection: promptRetrySelection,
            pairing: verified.pairing
        ) else {
            rejectPromptRetry(
                context: verifiedContext,
                generation: generation
            )
            return
        }
        verifiedContext = preparedRetry.context

        canRetry = false
        retryPrompt = nil
        retryFamiliarID = nil
        retryFamiliarPresentation = .empty
        retryTargetProfile = nil
        retriesPolling = false
        do {
            try await performSend(
                context: verifiedContext,
                pairing: verified,
                verification: verification,
                generation: generation,
                promptRetryFence: preparedRetry.launchFence
            )
        } catch {
            let contextualError = error as? CompanionContextualSendError
            handleSendFailure(
                contextualError?.underlying ?? error,
                context: contextualError?.context ?? verifiedContext,
                pairing: verified,
                verification: verification,
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
    // swiftlint:disable:next function_body_length
    func retry(
        currentFamiliarSelection: @escaping @MainActor () ->
            CompanionPromptRetrySelection = { .empty }
    ) async {
        guard !isBusy else { return }
        if pendingCleanup != nil {
            let prompt = retryPrompt
            let projectRoot = retryProjectRoot
            let familiarID = retryFamiliarID
            let familiarPresentation = retryFamiliarPresentation
            let targetProfile = retryTargetProfile
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
            retryTargetProfile = nil
            await send(
                prompt: prompt,
                projectRoot: projectRoot,
                familiarID: familiarID,
                familiar: familiarPresentation.familiar,
                familiarProfile: familiarPresentation.profile,
                targetProfile: targetProfile,
                promptRetrySelection: currentFamiliarSelection
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
        let targetProfile = retryTargetProfile
        retryPrompt = nil
        retryFamiliarID = nil
        retryFamiliarPresentation = .empty
        retryTargetProfile = nil
        await send(
            prompt: prompt,
            projectRoot: retryProjectRoot,
            familiarID: familiarID,
            familiar: familiarPresentation.familiar,
            familiarProfile: familiarPresentation.profile,
            targetProfile: targetProfile,
            promptRetrySelection: currentFamiliarSelection
        )
    }

    func promptRetryResolution(
        original: CompanionSendContext,
        currentSelection: CompanionPromptRetrySelection,
        pairing: DaemonPairing
    ) -> CompanionPromptRetryResolution? {
        guard original.familiarID != nil else {
            return CompanionPromptRetryResolution(
                context: original,
                requiresSelectionFence: false
            )
        }
        let endpointProfile = FamiliarProfileKey.companion(pairing: pairing)
        if original.familiarPresentation.profile?.normalized == endpointProfile {
            return CompanionPromptRetryResolution(
                context: original,
                requiresSelectionFence: false
            )
        }
        guard currentSelection.profile?.normalized == endpointProfile,
              let familiar = currentSelection.familiar,
              let selectedID = Self.normalizedFamiliarID(familiar.id),
              let settingsID = Self.normalizedFamiliarID(
                  currentSelection.familiarID
              ),
              selectedID.caseInsensitiveCompare(settingsID) == .orderedSame
        else {
            return nil
        }
        return CompanionPromptRetryResolution(
            context: CompanionSendContext(
                prompt: original.prompt,
                projectRoot: original.projectRoot,
                familiarID: selectedID,
                familiarPresentation: CompanionFamiliarPresentationContext(
                    familiar: familiar,
                    profile: endpointProfile
                ),
                targetProfile: original.targetProfile
            ),
            requiresSelectionFence: true
        )
    }

    func preparePromptRetry(
        original: CompanionSendContext,
        currentSelection: (
            @MainActor () -> CompanionPromptRetrySelection
        )?,
        pairing: DaemonPairing
    ) -> CompanionPreparedPromptRetry? {
        guard let currentSelection else {
            return CompanionPreparedPromptRetry(
                context: original,
                launchFence: nil
            )
        }
        guard let resolution = promptRetryResolution(
            original: original,
            currentSelection: currentSelection(),
            pairing: pairing
        ) else {
            return nil
        }
        let launchFence = resolution.requiresSelectionFence
            ? CompanionPromptRetryLaunchFence(
                originalContext: original,
                currentSelection: currentSelection
            )
            : nil
        return CompanionPreparedPromptRetry(
            context: resolution.context,
            launchFence: launchFence
        )
    }

    func promptRetryLaunchContext(
        _ fence: CompanionPromptRetryLaunchFence,
        pairing: DaemonPairing
    ) -> CompanionSendContext? {
        promptRetryResolution(
            original: fence.originalContext,
            currentSelection: fence.currentSelection(),
            pairing: pairing
        )?.context
    }

    func rejectPromptRetry(
        context: CompanionSendContext,
        generation: UInt64
    ) {
        guard generation == operationGeneration,
              !Task.isCancelled else {
            finishCancelledSend(generation: generation)
            return
        }
        isBusy = false
        setRetryContext(context)
        items.append(
            ChatItem(
                kind: .error,
                text: "Choose a familiar for this daemon before retrying."
            )
        )
    }

    func rejectPromptRetryDestination(
        context: CompanionSendContext,
        generation: UInt64
    ) {
        guard generation == operationGeneration,
              !Task.isCancelled else {
            finishCancelledSend(generation: generation)
            return
        }
        isBusy = false
        setRetryContext(context)
        items.append(
            ChatItem(
                kind: .error,
                text: "Re-pair with the daemon this prompt was prepared for before retrying."
            )
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
            retryPrompt = nil
            retryFamiliarID = nil
            retryFamiliarPresentation = .empty
            retryTargetProfile = nil
            retriesPolling = false
            if pendingCleanup == nil {
                canRetry = false
            }
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
        retryTargetProfile = nil

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
        retryTargetProfile = nil
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
