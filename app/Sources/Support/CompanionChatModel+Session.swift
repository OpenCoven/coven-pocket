// swiftlint:disable file_length

import Foundation

extension CompanionChatModel {
    // swiftlint:disable:next function_body_length
    func performSend(
        context: CompanionSendContext,
        pairing verified: VerifiedPairing,
        verification: CompanionOperationVerification,
        generation: UInt64,
        promptRetryFence: CompanionPromptRetryLaunchFence?
    ) async throws {
        guard !(await finishInvalidatedSendIfNeeded(
            context: context,
            generation: generation,
            pairing: verified,
            launchedSession: nil,
            activeSession: nil,
            verification: verification
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
            activeSession: session,
            verification: verification
        )) else { return }

        let reusedSession = try await sendInputIfSessionActive(
            context: context,
            pairing: verified,
            generation: generation
        )
        if reusedSession, session == nil {
            return
        }
        var finalizedContext = context
        var launchedSession: RemoteSession?
        if !reusedSession {
            guard let preparedLaunch = try await prepareAndLaunch(
                context: context,
                pairing: verified,
                verification: verification,
                generation: generation,
                promptRetryFence: promptRetryFence
            ) else { return }
            launchedSession = preparedLaunch.session
            finalizedContext = preparedLaunch.context
        }
        await finalizeSendIfCurrent(
            context: finalizedContext,
            pairing: verified,
            launchedSession: launchedSession,
            verification: verification,
            generation: generation
        )
    }

    func finalizeSendIfCurrent(
        context: CompanionSendContext,
        pairing verified: VerifiedPairing,
        launchedSession: RemoteSession?,
        verification: CompanionOperationVerification,
        generation: UInt64
    ) async {
        let finalVerification = launchedSession == nil
            ? CompanionOperationVerification(
                mode: .trafficEpoch,
                expectedTrafficEpoch: verified.trafficEpoch
            )
            : verification
        guard !(await finishInvalidatedSendIfNeeded(
            context: context,
            generation: generation,
            pairing: verified,
            launchedSession: launchedSession,
            activeSession: nil,
            verification: finalVerification
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
                activeSession: activeSession,
                verification: CompanionOperationVerification(
                    mode: .trafficEpoch,
                    expectedTrafficEpoch: verified.trafficEpoch
                )
            ) {
                return true
            }
            handleSessionTrafficFailure(
                error,
                context: context,
                pairing: verified,
                generation: generation
            )
            return true
        }
        let invalidated = await finishInvalidatedSendIfNeeded(
            context: context,
            generation: generation,
            pairing: verified,
            launchedSession: nil,
            activeSession: activeSession,
            verification: CompanionOperationVerification(
                mode: .trafficEpoch,
                expectedTrafficEpoch: verified.trafficEpoch
            )
        )
        if !invalidated {
            canRetry = false
            retryPrompt = nil
            retryFamiliarID = nil
            retryFamiliarPresentation = .empty
        }
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
        guard canPerformVerifiedOperation(
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
        guard canPerformVerifiedOperation(
            pairing: verifiedPairing,
            generation: generation
        ) else { return false }
        abandonSession()
        let cleaned = await beginCleanup(
            of: activeSession,
            pairing: sessionPairing,
            completionText: nil,
            verifiedPairing: verifiedPairing,
            trafficEpoch: verifiedPairing.trafficEpoch
        )
        guard generation == operationGeneration,
              !Task.isCancelled else {
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
        retryPrompt = nil
        retryFamiliarID = nil
        retryFamiliarPresentation = .empty
        isBusy = false
        await send(
            prompt: context.prompt,
            projectRoot: context.projectRoot,
            familiarID: context.familiarID,
            familiar: context.familiarPresentation.familiar,
            familiarProfile: context.familiarPresentation.profile,
            verificationMode: .trafficEpoch,
            expectedTrafficEpoch: verifiedPairing.trafficEpoch
        )
        return false
    }

    // swiftlint:disable:next function_body_length
    func prepareAndLaunch(
        context: CompanionSendContext,
        pairing verified: VerifiedPairing,
        verification: CompanionOperationVerification,
        generation: UInt64,
        promptRetryFence: CompanionPromptRetryLaunchFence?
    ) async throws -> CompanionPreparedLaunch? {
        guard !(await finishInvalidatedSendIfNeeded(
            context: context,
            generation: generation,
            pairing: verified,
            launchedSession: nil,
            activeSession: nil,
            verification: verification
        )) else { return nil }
        let launchContext: CompanionSendContext
        if let promptRetryFence {
            guard let refreshedContext = promptRetryLaunchContext(
                promptRetryFence,
                pairing: verified.pairing
            ) else {
                rejectPromptRetry(
                    context: promptRetryFence.originalContext,
                    generation: generation
                )
                return nil
            }
            launchContext = refreshedContext
        } else {
            launchContext = context
        }
        prepareForNewSession()
        let launched: RemoteSession
        do {
            launched = try await requestLaunch(
                context: launchContext,
                pairing: verified
            )
        } catch {
            guard !handleSupersededLaunchFailure(
                context: launchContext,
                pairing: verified,
                verification: verification,
                generation: generation
            ) else { return nil }
            throw error
        }
        if await discardReturnedLaunchIfNeeded(
            launched,
            pairing: verified,
            context: launchContext,
            verification: verification,
            generation: generation
        ) {
            return nil
        }
        guard try await confirmLaunchedFamiliar(
            launched,
            context: launchContext,
            pairing: verified,
            verification: verification,
            generation: generation
        ) else { return nil }
        guard !(await finishInvalidatedSendIfNeeded(
            context: launchContext,
            generation: generation,
            pairing: verified,
            launchedSession: launched,
            activeSession: nil,
            verification: verification
        )) else { return nil }
        adoptLaunchedSession(
            launched,
            context: launchContext,
            pairing: verified
        )
        return CompanionPreparedLaunch(
            session: launched,
            context: launchContext
        )
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
        verification: CompanionOperationVerification,
        generation: UInt64
    ) -> Bool {
        guard generation == operationGeneration,
              !Task.isCancelled,
              !verification.isCurrent(verified, on: self) else { return false }
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
        trafficAuthority = .ready(verified.pairing)
        trafficEpoch = verified.trafficEpoch
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
        verification: CompanionOperationVerification,
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
        guard verification.isCurrent(verified, on: self) else {
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
        verification: CompanionOperationVerification,
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
        guard verification.isCurrent(verified, on: self) else {
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

    func handleSessionTrafficFailure(
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
        guard isSessionTrafficCurrent(verified) else {
            settleSupersededSend(
                context: context,
                generation: generation
            )
            return
        }
        isBusy = false
        let sessionEnded = Self.isSessionNotLive(error)
        if sessionEnded {
            pollTask?.cancel()
            pollTask = nil
            sessionVerifiedPairing = nil
            abandonSession()
            pairing = nil
        }
        items.append(ChatItem(kind: .error, text: error.localizedDescription))
        setRetryContext(context)
        if sessionEnded {
            pollTask?.cancel()
            pollTask = nil
        } else {
            pollTask = nil
            startPolling(using: verified)
        }
    }

}

private struct FamiliarConfirmationError: LocalizedError {
    var errorDescription: String? {
        "The companion daemon did not confirm the selected familiar."
    }
}
