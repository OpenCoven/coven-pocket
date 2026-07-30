import Foundation

extension CompanionChatModel {
    func performSend(
        context: CompanionSendContext,
        pairing verified: DaemonPairing,
        generation: UInt64
    ) async throws {
        guard canContinueSend(generation: generation) else { return }
        guard try await replaceSessionIfNeeded(
            context: context,
            pairing: verified,
            generation: generation
        ) else {
            if Task.isCancelled {
                finishCancelledSend(generation: generation)
            }
            return
        }
        guard generation == operationGeneration, !Task.isCancelled else {
            finishCancelledSend(generation: generation)
            return
        }

        var launchedSession: RemoteSession?
        if let session {
            guard canContinueSend(generation: generation) else { return }
            try await client.sendInput(
                pairing: verified,
                sessionID: session.id,
                data: context.prompt
            )
            guard generation == operationGeneration, !Task.isCancelled else {
                finishCancelledSend(generation: generation)
                return
            }
        } else {
            try await prepareAndLaunch(
                context: context,
                pairing: verified,
                generation: generation
            )
            launchedSession = session
        }
        if await finishInvalidatedSendIfNeeded(
            generation: generation,
            pairing: verified,
            launchedSession: launchedSession
        ) {
            return
        }
        await finalizeSend(
            verified,
            generation: generation,
            launchedSession: launchedSession
        )
    }

    func replaceSessionIfNeeded(
        context: CompanionSendContext,
        pairing: DaemonPairing,
        generation: UInt64
    ) async throws -> Bool {
        guard let activeSession = session else { return true }
        guard let sessionPairing = self.pairing else {
            abandonSession()
            return true
        }
        guard Self.isSameDaemonEndpoint(sessionPairing, pairing) else {
            guard canContinueSend(generation: generation) else { return false }
            abandonSession()
            await beginCleanup(
                of: activeSession,
                pairing: sessionPairing,
                completionText: nil
            )
            return false
        }
        guard Self.isSameDaemonInstance(sessionPairing, pairing) else {
            abandonSession()
            return true
        }
        guard sessionProjectRoot != context.projectRoot
                || sessionFamiliarID != context.familiarID else { return true }
        guard canContinueSend(generation: generation) else { return false }
        abandonSession()
        let cleaned = await beginCleanup(
            of: activeSession,
            pairing: sessionPairing,
            completionText: nil
        )
        guard generation == operationGeneration,
              !Task.isCancelled else { return false }
        guard cleaned else {
            setRetryContext(
                context
            )
            return false
        }
        isBusy = true
        return true
    }

    func prepareSessionForPollingRetry(
        pairing verified: DaemonPairing
    ) async -> Bool {
        guard let activeSession = session,
              let sessionPairing = pairing else {
            isBusy = false
            canRetry = false
            retriesPolling = false
            return false
        }
        guard Self.isSameDaemonEndpoint(sessionPairing, verified) else {
            abandonSession()
            await beginCleanup(
                of: activeSession,
                pairing: sessionPairing,
                completionText: nil
            )
            return false
        }
        guard Self.isSameDaemonInstance(sessionPairing, verified) else {
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
            isBusy = false
            canRetry = true
            return
        }
        let prepared = await prepareSessionForPollingRetry(pairing: verified)
        guard !finishInvalidatedPollingRetryIfNeeded(
            generation: generation
        ) else { return }
        guard prepared else { return }
        pairing = verified
        retriesPolling = false
        canRetry = false
        await refreshOnce()
        guard !finishInvalidatedPollingRetryIfNeeded(
            generation: generation
        ) else { return }
        if session != nil, isBusy, !retriesPolling {
            startPolling()
        }
    }

    func prepareAndLaunch(
        context: CompanionSendContext,
        pairing: DaemonPairing,
        generation: UInt64
    ) async throws {
        prepareForNewSession()
        guard generation == operationGeneration, !Task.isCancelled else {
            finishCancelledSend(generation: generation)
            return
        }
        launchInFlight = true
        do {
            let launched = try await client.launch(
                pairing: pairing,
                projectRoot: context.projectRoot,
                prompt: context.prompt,
                title: Self.title(from: context.prompt),
                familiarID: context.familiarID
            )
            launchInFlight = false
            if await discardReturnedLaunchIfNeeded(
                launched,
                pairing: pairing,
                generation: generation
            ) {
                return
            }
            guard try await confirmLaunchedFamiliar(
                launched,
                context: context,
                pairing: pairing,
                generation: generation
            ) else { return }
            guard generation == operationGeneration,
                  !Task.isCancelled else {
                _ = await discardReturnedLaunchIfNeeded(
                    launched,
                    pairing: pairing,
                    generation: generation
                )
                return
            }
            adoptLaunchedSession(
                launched,
                context: context,
                pairing: pairing
            )
        } catch {
            launchInFlight = false
            throw error
        }
    }

    func adoptLaunchedSession(
        _ launched: RemoteSession,
        context: CompanionSendContext,
        pairing: DaemonPairing
    ) {
        session = launched
        sessionProjectRoot = context.projectRoot
        pinSessionFamiliar(
            id: context.familiarID,
            presentation: context.familiarPresentation,
            pairing: pairing
        )
        initialPrompt = context.prompt
        initialPromptID = "companion-initial-\(launched.id)"
        items = [
            ChatItem(
                id: initialPromptID ?? "companion-initial",
                kind: .user,
                text: context.prompt
            )
        ]
    }

    func confirmLaunchedFamiliar(
        _ launched: RemoteSession,
        context: CompanionSendContext,
        pairing: DaemonPairing,
        generation: UInt64
    ) async throws -> Bool {
        guard launched.familiarId != context.familiarID else { return true }
        await cleanupReturnedLaunch(
            of: launched,
            pairing: pairing,
            revalidatePairing: false
        )
        guard generation == operationGeneration,
              !Task.isCancelled else {
            finishCancelledSend(generation: generation)
            return false
        }
        throw FamiliarConfirmationError()
    }

    func handleSendFailure(
        _ error: Error,
        context: CompanionSendContext,
        generation: UInt64
    ) {
        guard generation == operationGeneration else {
            if pendingCleanup == nil {
                isBusy = false
            }
            return
        }
        guard !Task.isCancelled else {
            finishCancelledSend(generation: generation)
            return
        }
        isBusy = false
        if Self.isSessionNotLive(error) {
            abandonSession()
        }
        items.append(ChatItem(kind: .error, text: error.localizedDescription))
        setRetryContext(context)
    }

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
    ) async -> DaemonPairing? {
        guard generation == operationGeneration,
              !Task.isCancelled else { return nil }
        guard let gate = await availabilityGate(
            while: { generation == operationGeneration }
        ) else { return nil }
        guard generation == operationGeneration,
              !Task.isCancelled else { return nil }
        switch gate {
        case let .ready(pairing):
            return pairing
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

    func startPolling() {
        guard pollTask == nil, !Task.isCancelled else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOnce()
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

    func canContinueSend(generation: UInt64) -> Bool {
        guard generation == operationGeneration,
              !Task.isCancelled else {
            finishCancelledSend(generation: generation)
            return false
        }
        return true
    }
}

private struct FamiliarConfirmationError: LocalizedError {
    var errorDescription: String? {
        "The companion daemon did not confirm the selected familiar."
    }
}
