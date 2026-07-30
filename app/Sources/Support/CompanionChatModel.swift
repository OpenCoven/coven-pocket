import Foundation

@MainActor
final class CompanionChatModel: ObservableObject {
    enum Availability: Equatable {
        case checking
        case ready(DaemonPairing)
        case blocked(reason: String, hint: String)
    }

    @Published var items: [ChatItem] = []
    @Published var isBusy = false
    @Published var canRetry = false
    @Published var availability: Availability = .checking

    var cursor: Int64 = 0

    static let requestTimeoutMs: UInt32 = 6_000
    static let pageLimit: UInt32 = 200
    static let pollInterval: Duration = .seconds(2)

    let companion: CompanionModel
    let client: any CompanionSessionClient
    var pairing: DaemonPairing?
    var session: RemoteSession?
    var sessionProjectRoot: String?
    var sessionFamiliarID: String?
    var accumulatedEvents: [RemoteEvent] = []
    var retryPrompt: String?
    var retryProjectRoot = ""
    var retryFamiliarID: String?
    var pollTask: Task<Void, Never>?
    var lastCompletedResultSeq: Int64 = 0
    var initialPrompt: String?
    var initialPromptID: String?
    var retriesPolling = false
    var operationGeneration: UInt64 = 0
    var availabilityGeneration: UInt64 = 0
    var launchInFlight = false
    var pendingCleanup: RemoteSession?
    var pendingCleanupPairing: DaemonPairing?
    var pendingCleanupCompletionText: String?

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

    var hasPendingCleanup: Bool {
        pendingCleanup != nil
    }

    var hasActivePollTask: Bool {
        pollTask != nil
    }

    func refreshAvailability() async {
        let generation = beginAvailabilityCheck()
        let gate = await client.sessionGate()
        guard generation == availabilityGeneration else { return }
        availability = Self.availability(from: gate)
    }

    func beginAvailabilityCheck() -> UInt64 {
        availabilityGeneration &+= 1
        availability = .checking
        return availabilityGeneration
    }

    func send(
        prompt: String,
        projectRoot: String,
        familiarID: String? = nil
    ) async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFamiliarID = Self.normalizedFamiliarID(familiarID)
        guard !trimmedPrompt.isEmpty, !isBusy, pendingCleanup == nil else { return }
        guard Self.isAbsoluteHostPath(trimmedRoot) else {
            retryFamiliarID = nil
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
        guard let verified = await verifiedPairing(
            reportFailure: true,
            generation: generation
        ) else {
            guard generation == operationGeneration else { return }
            isBusy = false
            retryPrompt = trimmedPrompt
            canRetry = true
            return
        }

        canRetry = false
        retryPrompt = nil
        retryFamiliarID = nil
        retriesPolling = false
        do {
            try await performSend(
                prompt: trimmedPrompt,
                projectRoot: trimmedRoot,
                familiarID: normalizedFamiliarID,
                pairing: verified,
                generation: generation
            )
        } catch {
            handleSendFailure(
                error,
                prompt: trimmedPrompt,
                projectRoot: trimmedRoot,
                familiarID: normalizedFamiliarID,
                generation: generation
            )
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
            await send(
                prompt: prompt,
                projectRoot: projectRoot,
                familiarID: familiarID
            )
            return
        }
        if retriesPolling {
            await retryPolling()
            return
        }
        guard let prompt = retryPrompt else { return }
        let familiarID = retryFamiliarID
        retryPrompt = nil
        retryFamiliarID = nil
        await send(
            prompt: prompt,
            projectRoot: retryProjectRoot,
            familiarID: familiarID
        )
    }

    func refreshOnce() async {
        let generation = operationGeneration
        guard let pairing, let session else { return }
        do {
            var hasMore = true
            while hasMore && !Task.isCancelled {
                let page = try await client.events(
                    pairing: pairing,
                    sessionID: session.id,
                    afterSeq: cursor
                )
                guard generation == operationGeneration,
                      !Task.isCancelled else { return }
                let knownSequences = Set(accumulatedEvents.map(\.seq))
                accumulatedEvents.append(
                    contentsOf: page.events.filter { !knownSequences.contains($0.seq) }
                )
                cursor = max(cursor, page.nextAfterSeq)
                hasMore = page.hasMore
            }
            guard generation == operationGeneration,
                  !Task.isCancelled else { return }
            apply(events: accumulatedEvents)
        } catch {
            guard generation == operationGeneration,
                  !Task.isCancelled else { return }
            let wasAwaitingResult = isBusy
            items.append(ChatItem(kind: .error, text: error.localizedDescription))
            pollTask?.cancel()
            pollTask = nil
            isBusy = false
            if Self.isSessionNotLive(error) {
                abandonSession()
                retriesPolling = false
                canRetry = false
            } else {
                retriesPolling = wasAwaitingResult
                canRetry = wasAwaitingResult
            }
        }
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
        session = nil
        sessionProjectRoot = nil
        sessionFamiliarID = nil
        canRetry = false
        retriesPolling = false
        retryPrompt = nil
        retryFamiliarID = nil

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
        session = nil
        sessionProjectRoot = nil
        sessionFamiliarID = nil
        accumulatedEvents = []
        cursor = 0
        lastCompletedResultSeq = 0
        initialPrompt = nil
        initialPromptID = nil
        retriesPolling = false
        retryPrompt = nil
        retryProjectRoot = ""
        retryFamiliarID = nil
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
}
