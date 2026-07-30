import Foundation

extension CompanionChatModel {
    func performSend(
        prompt: String,
        projectRoot: String,
        pairing verified: DaemonPairing,
        generation: UInt64
    ) async throws {
        guard try await replaceSessionIfNeeded(
            projectRoot: projectRoot,
            pairing: verified,
            generation: generation
        ) else { return }
        guard generation == operationGeneration else { return }

        if let session {
            try await client.sendInput(
                pairing: verified,
                sessionID: session.id,
                data: prompt
            )
        } else {
            try await prepareAndLaunch(
                prompt: prompt,
                projectRoot: projectRoot,
                pairing: verified,
                generation: generation
            )
        }
        guard generation == operationGeneration else { return }
        pairing = verified
        startPolling()
    }

    func replaceSessionIfNeeded(
        projectRoot: String,
        pairing: DaemonPairing,
        generation: UInt64
    ) async throws -> Bool {
        guard let activeSession = session else { return true }
        guard let sessionPairing = self.pairing else {
            abandonSession()
            return true
        }
        guard Self.isSameDaemonEndpoint(sessionPairing, pairing) else {
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
        guard sessionProjectRoot != projectRoot else { return true }
        do {
            try await client.kill(pairing: pairing, sessionID: activeSession.id)
        } catch {
            guard Self.isSessionNotLive(error) else { throw error }
        }
        guard generation == operationGeneration else { return false }
        abandonSession()
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
        guard let verified = await verifiedPairing(
            reportFailure: true,
            generation: generation
        ) else {
            guard generation == operationGeneration else { return }
            isBusy = false
            canRetry = true
            return
        }
        guard generation == operationGeneration,
              await prepareSessionForPollingRetry(pairing: verified),
              generation == operationGeneration else { return }
        pairing = verified
        retriesPolling = false
        canRetry = false
        await refreshOnce()
        guard generation == operationGeneration else { return }
        if session != nil, !retriesPolling {
            startPolling()
        }
    }

    func prepareAndLaunch(
        prompt: String,
        projectRoot: String,
        pairing: DaemonPairing,
        generation: UInt64
    ) async throws {
        prepareForNewSession()
        launchInFlight = true
        do {
            let launched = try await client.launch(
                pairing: pairing,
                projectRoot: projectRoot,
                prompt: prompt,
                title: Self.title(from: prompt)
            )
            launchInFlight = false
            guard generation == operationGeneration else {
                await beginCleanup(
                    of: launched,
                    pairing: pairing,
                    completionText: nil
                )
                return
            }
            session = launched
            sessionProjectRoot = projectRoot
            initialPrompt = prompt
            initialPromptID = "companion-initial-\(launched.id)"
            items = [
                ChatItem(
                    id: initialPromptID ?? "companion-initial",
                    kind: .user,
                    text: prompt
                )
            ]
        } catch {
            launchInFlight = false
            throw error
        }
    }

    func handleSendFailure(
        _ error: Error,
        prompt: String,
        generation: UInt64
    ) {
        guard generation == operationGeneration else {
            if pendingCleanup == nil {
                isBusy = false
            }
            return
        }
        isBusy = false
        if Self.isSessionNotLive(error) {
            abandonSession()
        }
        fail(error.localizedDescription, retryPrompt: prompt)
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
        let availabilityRequest = beginAvailabilityCheck()
        let gate = await client.sessionGate()
        guard generation == operationGeneration,
              availabilityRequest == availabilityGeneration else { return nil }
        availability = Self.availability(from: gate)
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
        guard pollTask == nil else { return }
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
        session = nil
        sessionProjectRoot = nil
    }
}
