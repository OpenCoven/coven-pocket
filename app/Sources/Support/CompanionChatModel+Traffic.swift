import Foundation

struct VerifiedPairing: Equatable {
    let pairing: DaemonPairing
    let availabilityGeneration: UInt64
}

extension CompanionChatModel {
    static func availability(
        from gate: CompanionModel.SessionGate
    ) -> Availability {
        switch gate {
        case let .ready(pairing):
            return .ready(pairing)
        case .notPaired:
            return .blocked(
                reason: "Not paired",
                hint: "Pair with a daemon in the Companion tab first."
            )
        case let .blocked(reason, hint):
            return .blocked(reason: reason, hint: hint)
        }
    }

    func verifiedPairing(
        reportFailure: Bool,
        generation: UInt64
    ) async -> VerifiedPairing? {
        guard generation == operationGeneration,
              !Task.isCancelled else { return nil }
        guard let result = await availabilityGate(
            while: { generation == operationGeneration }
        ) else { return nil }
        guard generation == operationGeneration,
              !Task.isCancelled else { return nil }
        switch result.gate {
        case let .ready(pairing):
            let verified = VerifiedPairing(
                pairing: pairing,
                availabilityGeneration: result.availabilityGeneration
            )
            guard isVerifiedPairingCurrent(verified) else { return nil }
            return verified
        case .notPaired:
            if reportFailure {
                fail(
                    "Not paired. Pair with a daemon in the Companion tab first.",
                    retryPrompt: nil
                )
            }
        case let .blocked(reason, hint):
            if reportFailure {
                fail("\(reason). \(hint)", retryPrompt: nil)
            }
        }
        return nil
    }

    func finishUnverifiedSend(
        context: CompanionSendContext,
        generation: UInt64
    ) async {
        guard generation == operationGeneration else { return }
        guard !Task.isCancelled else {
            finishCancelledSend(generation: generation)
            return
        }
        if let sessionVerifiedPairing,
           !isVerifiedPairingCurrent(sessionVerifiedPairing) {
            await discardSessionForSupersededPairingIfNeeded(
                pairing: sessionVerifiedPairing,
                generation: generation
            )
            guard generation == operationGeneration,
                  !Task.isCancelled else { return }
        }
        isBusy = false
        setRetryContext(context)
    }

    func finishUnverifiedPollingRetry(generation: UInt64) async {
        guard generation == operationGeneration,
              !Task.isCancelled else { return }
        if let sessionVerifiedPairing,
           !isVerifiedPairingCurrent(sessionVerifiedPairing) {
            await discardSessionForSupersededPairingIfNeeded(
                pairing: sessionVerifiedPairing,
                generation: generation
            )
            guard generation == operationGeneration,
                  !Task.isCancelled else { return }
            retriesPolling = false
            if pendingCleanup == nil {
                isBusy = false
                canRetry = false
            }
            return
        }
        isBusy = false
        canRetry = true
    }

    func prepareSessionForPollingRetry(
        pairing verified: VerifiedPairing
    ) async -> Bool {
        guard let activeSession = session,
              let sessionPairing = pairing else {
            isBusy = false
            canRetry = false
            retriesPolling = false
            return false
        }
        guard Self.isSameDaemonEndpoint(
            sessionPairing,
            verified.pairing
        ) else {
            abandonSession()
            await beginCleanup(
                of: activeSession,
                pairing: sessionPairing,
                completionText: nil
            )
            return false
        }
        guard Self.isSameDaemonInstance(
            sessionPairing,
            verified.pairing
        ) else {
            abandonSession()
            isBusy = false
            canRetry = false
            retriesPolling = false
            items.append(
                ChatItem(
                    kind: .error,
                    text: "The companion daemon restarted. Send the prompt again."
                )
            )
            return false
        }
        return true
    }

    // swiftlint:disable:next function_body_length
    func retryPolling() async {
        operationGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        let generation = operationGeneration
        isBusy = true
        defer { _ = finishInvalidatedPollingRetryIfNeeded(generation: generation) }
        let verified = await verifiedPairing(
            reportFailure: true,
            generation: generation
        )
        guard !finishInvalidatedPollingRetryIfNeeded(
            generation: generation
        ) else { return }
        guard let verified else {
            await finishUnverifiedPollingRetry(generation: generation)
            return
        }
        guard canPerformSessionTraffic(
            pairing: verified,
            generation: generation
        ) else {
            await discardSessionForSupersededPairingIfNeeded(
                pairing: verified,
                generation: generation
            )
            return
        }
        let prepared = await prepareSessionForPollingRetry(pairing: verified)
        guard !finishInvalidatedPollingRetryIfNeeded(
            generation: generation
        ) else { return }
        guard prepared else { return }
        guard canPerformSessionTraffic(
            pairing: verified,
            generation: generation
        ) else {
            await discardSessionForSupersededPairingIfNeeded(
                pairing: verified,
                generation: generation
            )
            return
        }
        pairing = verified.pairing
        sessionVerifiedPairing = verified
        retriesPolling = false
        canRetry = false
        let refreshed = await refreshOnce(using: verified)
        guard !finishInvalidatedPollingRetryIfNeeded(
            generation: generation
        ) else { return }
        guard refreshed else { return }
        if session != nil,
           isBusy,
           !retriesPolling,
           canPerformSessionTraffic(
               pairing: verified,
               generation: generation
           ) {
            startPolling(using: verified)
        }
    }

    func refreshOnce() async {
        guard let sessionVerifiedPairing else { return }
        _ = await refreshOnce(using: sessionVerifiedPairing)
    }

    @discardableResult
    func refreshOnce(using verified: VerifiedPairing) async -> Bool {
        let generation = operationGeneration
        guard let session else { return false }
        guard await continuePollingTraffic(
            pairing: verified,
            generation: generation
        ) else { return false }
        do {
            var hasMore = true
            while hasMore && !Task.isCancelled {
                guard await continuePollingTraffic(
                    pairing: verified,
                    generation: generation
                ) else { return false }
                let page = try await client.events(
                    pairing: verified.pairing,
                    sessionID: session.id,
                    afterSeq: cursor
                )
                guard await continuePollingTraffic(
                    pairing: verified,
                    generation: generation
                ) else { return false }
                let knownSequences = Set(accumulatedEvents.map(\.seq))
                accumulatedEvents.append(
                    contentsOf: page.events.filter { !knownSequences.contains($0.seq) }
                )
                cursor = max(cursor, page.nextAfterSeq)
                hasMore = page.hasMore
            }
            guard await continuePollingTraffic(
                pairing: verified,
                generation: generation
            ) else { return false }
            apply(events: accumulatedEvents)
            return true
        } catch {
            guard await continuePollingTraffic(
                pairing: verified,
                generation: generation
            ) else { return false }
            handlePollingFailure(error)
            return false
        }
    }

    func continuePollingTraffic(
        pairing verified: VerifiedPairing,
        generation: UInt64
    ) async -> Bool {
        guard canPerformSessionTraffic(
            pairing: verified,
            generation: generation
        ) else {
            await discardSessionForSupersededPairingIfNeeded(
                pairing: verified,
                generation: generation
            )
            return false
        }
        return true
    }

    func handlePollingFailure(_ error: Error) {
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

    func startPolling() {
        guard let sessionVerifiedPairing else { return }
        startPolling(using: sessionVerifiedPairing)
    }

    func startPolling(using verified: VerifiedPairing) {
        guard pollTask == nil, !Task.isCancelled else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let refreshed = await self.refreshOnce(using: verified)
                guard refreshed else { return }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func prepareForNewSession() {
        pollTask?.cancel()
        pollTask = nil
        accumulatedEvents = []
        cursor = 0
        lastCompletedResultSeq = 0
        initialPrompt = nil
        initialPromptID = nil
        retriesPolling = false
        items = []
    }

    func abandonSession() {
        pollTask?.cancel()
        pollTask = nil
        clearSessionBinding()
    }

    func setRetryContext(_ context: CompanionSendContext) {
        retryPrompt = context.prompt
        retryProjectRoot = context.projectRoot
        retryFamiliarID = context.familiarID
        retryFamiliarPresentation = context.familiarPresentation
        canRetry = true
    }

    func finishCancelledSend(generation: UInt64) {
        guard generation == operationGeneration else { return }
        retryPrompt = nil
        retryFamiliarID = nil
        retryFamiliarPresentation = .empty
        retriesPolling = false
        guard pendingCleanup == nil else { return }
        isBusy = false
        canRetry = false
    }

    func settleSupersededSend(
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
    }

    func canPerformSessionTraffic(
        pairing verified: VerifiedPairing,
        generation: UInt64
    ) -> Bool {
        generation == operationGeneration
            && !Task.isCancelled
            && isVerifiedPairingCurrent(verified)
    }

    func isVerifiedPairingCurrent(_ verified: VerifiedPairing) -> Bool {
        guard verified.availabilityGeneration == availabilityGeneration,
              case let .ready(currentPairing) = availability else {
            return false
        }
        return Self.isSameDaemonInstance(
            currentPairing,
            verified.pairing
        )
    }
}
