import Foundation

extension CompanionChatModel {
    func performSend(
        context: CompanionSendContext,
        pairing verified: VerifiedPairing,
        generation: UInt64
    ) async throws {
        guard !(await finishInvalidatedSendIfNeeded(
            context: context,
            generation: generation,
            pairing: verified,
            launchedSession: nil,
            activeSession: nil
        )) else { return }
        guard await replaceSessionIfNeeded(
            context: context,
            pairing: verified,
            generation: generation
        ) else {
            if Task.isCancelled {
                finishCancelledSend(generation: generation)
            }
            return
        }
        guard !(await finishInvalidatedSendIfNeeded(
            context: context,
            generation: generation,
            pairing: verified,
            launchedSession: nil,
            activeSession: session
        )) else { return }

        let reusedSession = try await sendInputIfSessionActive(
            context: context,
            pairing: verified,
            generation: generation
        )
        var launchedSession: RemoteSession?
        if !reusedSession {
            guard let launched = try await prepareAndLaunch(
                context: context,
                pairing: verified,
                generation: generation
            ) else { return }
            launchedSession = launched
        }
        await finalizeSendIfCurrent(
            context: context,
            pairing: verified,
            launchedSession: launchedSession,
            generation: generation
        )
    }

    func finalizeSendIfCurrent(
        context: CompanionSendContext,
        pairing verified: VerifiedPairing,
        launchedSession: RemoteSession?,
        generation: UInt64
    ) async {
        guard !(await finishInvalidatedSendIfNeeded(
            context: context,
            generation: generation,
            pairing: verified,
            launchedSession: launchedSession,
            activeSession: nil
        )) else { return }
        if let launchedSession,
           session?.id != launchedSession.id
            || sessionVerifiedPairing != verified {
            await discardAdoptedLaunch(
                launchedSession,
                pairing: verified,
                generation: generation
            )
            return
        }
        await finalizeSend(
            verified,
            generation: generation,
            launchedSession: launchedSession
        )
    }

    func sendInputIfSessionActive(
        context: CompanionSendContext,
        pairing verified: VerifiedPairing,
        generation: UInt64
    ) async throws -> Bool {
        guard let activeSession = session else { return false }
        pairing = verified.pairing
        sessionVerifiedPairing = verified
        do {
            try await client.sendInput(
                pairing: verified.pairing,
                sessionID: activeSession.id,
                data: context.prompt
            )
        } catch {
            if await finishInvalidatedSendIfNeeded(
                context: context,
                generation: generation,
                pairing: verified,
                launchedSession: nil,
                activeSession: activeSession
            ) {
                return true
            }
            throw error
        }
        _ = await finishInvalidatedSendIfNeeded(
            context: context,
            generation: generation,
            pairing: verified,
            launchedSession: nil,
            activeSession: activeSession
        )
        return true
    }

    func replaceSessionIfNeeded(
        context: CompanionSendContext,
        pairing verified: VerifiedPairing,
        generation: UInt64
    ) async -> Bool {
        guard let activeSession = session else { return true }
        guard let sessionPairing = self.pairing else {
            abandonSession()
            return true
        }
        guard Self.isSameDaemonEndpoint(
            sessionPairing,
            verified.pairing
        ) else {
            return await replaceSessionFromDifferentEndpoint(
                activeSession,
                pairing: sessionPairing,
                context: context,
                verifiedPairing: verified,
                generation: generation
            )
        }
        guard Self.isSameDaemonInstance(
            sessionPairing,
            verified.pairing
        ) else {
            abandonSession()
            return true
        }
        guard sessionProjectRoot != context.projectRoot
                || sessionFamiliarID != context.familiarID else { return true }
        return await replaceSessionForChangedContext(
            activeSession,
            pairing: sessionPairing,
            context: context,
            verifiedPairing: verified,
            generation: generation
        )
    }

    func replaceSessionFromDifferentEndpoint(
        _ activeSession: RemoteSession,
        pairing sessionPairing: DaemonPairing,
        context: CompanionSendContext,
        verifiedPairing: VerifiedPairing,
        generation: UInt64
    ) async -> Bool {
        guard canPerformSessionTraffic(
            pairing: verifiedPairing,
            generation: generation
        ) else { return false }
        abandonSession()
        await beginCleanup(
            of: activeSession,
            pairing: sessionPairing,
            completionText: nil
        )
        guard generation == operationGeneration,
              !Task.isCancelled else { return false }
        setRetryContext(context)
        isBusy = false
        return false
    }

    func replaceSessionForChangedContext(
        _ activeSession: RemoteSession,
        pairing sessionPairing: DaemonPairing,
        context: CompanionSendContext,
        verifiedPairing: VerifiedPairing,
        generation: UInt64
    ) async -> Bool {
        guard canPerformSessionTraffic(
            pairing: verifiedPairing,
            generation: generation
        ) else { return false }
        abandonSession()
        let cleaned = await beginCleanup(
            of: activeSession,
            pairing: sessionPairing,
            completionText: nil,
            verifiedPairing: verifiedPairing
        )
        guard canPerformSessionTraffic(
            pairing: verifiedPairing,
            generation: generation
        ) else {
            if generation == operationGeneration, !Task.isCancelled {
                setRetryContext(context)
                isBusy = false
            }
            return false
        }
        guard cleaned else {
            setRetryContext(context)
            return false
        }
        isBusy = true
        return true
    }

    func prepareAndLaunch(
        context: CompanionSendContext,
        pairing verified: VerifiedPairing,
        generation: UInt64
    ) async throws -> RemoteSession? {
        prepareForNewSession()
        guard !(await finishInvalidatedSendIfNeeded(
            context: context,
            generation: generation,
            pairing: verified,
            launchedSession: nil,
            activeSession: nil
        )) else { return nil }
        let launched: RemoteSession
        do {
            launched = try await requestLaunch(
                context: context,
                pairing: verified
            )
        } catch {
            guard !handleSupersededLaunchFailure(
                context: context,
                pairing: verified,
                generation: generation
            ) else { return nil }
            throw error
        }
        if await discardReturnedLaunchIfNeeded(
            launched,
            pairing: verified,
            context: context,
            generation: generation
        ) {
            return nil
        }
        guard try await confirmLaunchedFamiliar(
            launched,
            context: context,
            pairing: verified,
            generation: generation
        ) else { return nil }
        guard !(await finishInvalidatedSendIfNeeded(
            context: context,
            generation: generation,
            pairing: verified,
            launchedSession: launched,
            activeSession: nil
        )) else { return nil }
        adoptLaunchedSession(
            launched,
            context: context,
            pairing: verified
        )
        return launched
    }

    func requestLaunch(
        context: CompanionSendContext,
        pairing verified: VerifiedPairing
    ) async throws -> RemoteSession {
        launchInFlight = true
        defer { launchInFlight = false }
        return try await client.launch(
            pairing: verified.pairing,
            projectRoot: context.projectRoot,
            prompt: context.prompt,
            title: Self.title(from: context.prompt),
            familiarID: context.familiarID
        )
    }

    func handleSupersededLaunchFailure(
        context: CompanionSendContext,
        pairing verified: VerifiedPairing,
        generation: UInt64
    ) -> Bool {
        guard generation == operationGeneration,
              !Task.isCancelled,
              !isVerifiedPairingCurrent(verified) else { return false }
        settleSupersededSend(
            context: context,
            generation: generation
        )
        return true
    }

    func adoptLaunchedSession(
        _ launched: RemoteSession,
        context: CompanionSendContext,
        pairing verified: VerifiedPairing
    ) {
        session = launched
        pairing = verified.pairing
        sessionVerifiedPairing = verified
        sessionProjectRoot = context.projectRoot
        pinSessionFamiliar(
            id: context.familiarID,
            presentation: context.familiarPresentation,
            pairing: verified.pairing
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
        pairing verified: VerifiedPairing,
        generation: UInt64
    ) async throws -> Bool {
        guard launched.familiarId != context.familiarID else { return true }
        await cleanupReturnedLaunch(
            of: launched,
            pairing: verified,
            revalidatePairing: false
        )
        guard generation == operationGeneration,
              !Task.isCancelled else {
            finishCancelledSend(generation: generation)
            return false
        }
        guard isVerifiedPairingCurrent(verified) else {
            settleSupersededSend(
                context: context,
                generation: generation
            )
            return false
        }
        throw FamiliarConfirmationError()
    }

    func handleSendFailure(
        _ error: Error,
        context: CompanionSendContext,
        pairing verified: VerifiedPairing,
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
        guard isVerifiedPairingCurrent(verified) else {
            settleSupersededSend(
                context: context,
                generation: generation
            )
            return
        }
        isBusy = false
        if Self.isSessionNotLive(error) {
            abandonSession()
        }
        items.append(ChatItem(kind: .error, text: error.localizedDescription))
        setRetryContext(context)
    }

}

private struct FamiliarConfirmationError: LocalizedError {
    var errorDescription: String? {
        "The companion daemon did not confirm the selected familiar."
    }
}
