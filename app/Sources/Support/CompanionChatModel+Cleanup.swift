import Foundation

// swiftlint:disable file_length

private struct CompanionCleanupRequest {
    let session: RemoteSession
    let generation: UInt64
    let completionText: String?
    let ownershipToken: UInt64
}

private struct CompanionCleanupAuthority {
    let verifiedPairing: VerifiedPairing
    let allowsSupersededPairing: Bool
}

extension CompanionChatModel {
    func retryPendingCleanup() async {
        guard let pendingCleanup else { return }
        await beginCleanup(
            of: pendingCleanup,
            pairing: pendingCleanupPairing,
            completionText: pendingCleanupCompletionText
        )
    }

    func discardReturnedLaunchIfNeeded(
        _ launched: RemoteSession,
        pairing verified: VerifiedPairing,
        context: CompanionSendContext,
        generation: UInt64
    ) async -> Bool {
        let operationInvalidated = generation != operationGeneration
        let cancelled = Task.isCancelled
        let pairingInvalidated = !isVerifiedPairingCurrent(verified)
        guard operationInvalidated
                || cancelled
                || pairingInvalidated else { return false }
        await cleanupReturnedLaunch(
            of: launched,
            pairing: verified,
            revalidatePairing: operationInvalidated
        )
        if pairingInvalidated,
           !operationInvalidated,
           !cancelled {
            settleSupersededSend(
                context: context,
                generation: generation
            )
        } else if cancelled {
            finishCancelledSend(generation: generation)
        }
        return true
    }

    func finishInvalidatedSendIfNeeded(
        context: CompanionSendContext,
        generation: UInt64,
        pairing verified: VerifiedPairing,
        launchedSession: RemoteSession?,
        activeSession: RemoteSession?
    ) async -> Bool {
        let operationInvalidated = generation != operationGeneration
        let cancelled = Task.isCancelled
        if operationInvalidated || cancelled {
            if let launchedSession {
                await discardAdoptedLaunch(
                    launchedSession,
                    pairing: verified,
                    generation: generation
                )
            }
            finishCancelledSend(generation: generation)
            return true
        }
        guard !isVerifiedPairingCurrent(verified) else { return false }
        if let launchedSession {
            await discardAdoptedLaunch(
                launchedSession,
                pairing: verified,
                generation: generation
            )
        } else if let activeSession {
            await discardSessionForSupersededPairingIfNeeded(
                activeSession,
                pairing: verified,
                generation: generation
            )
        }
        settleSupersededSend(
            context: context,
            generation: generation
        )
        return true
    }

    func finalizeSend(
        _ verified: VerifiedPairing,
        generation: UInt64,
        launchedSession: RemoteSession?
    ) async {
        pairing = verified.pairing
        sessionVerifiedPairing = verified
        startPolling(using: verified)
        _ = await finishPollingIfCancelled(
            generation: generation,
            pairing: verified,
            launchedSession: launchedSession
        )
    }

    func finishPollingIfCancelled(
        generation: UInt64,
        pairing: VerifiedPairing,
        launchedSession: RemoteSession?
    ) async -> Bool {
        guard Task.isCancelled else { return false }
        pollTask?.cancel()
        pollTask = nil
        if let launchedSession {
            await discardAdoptedLaunch(
                launchedSession,
                pairing: pairing,
                generation: generation
            )
        }
        finishCancelledSend(generation: generation)
        return true
    }

    func discardAdoptedLaunch(
        _ launched: RemoteSession,
        pairing: VerifiedPairing,
        generation: UInt64
    ) async {
        if session?.id == launched.id {
            guard sessionVerifiedPairing == pairing else { return }
            abandonSession()
            prepareForNewSession()
        }
        guard pendingCleanup?.id != launched.id else { return }
        await cleanupReturnedLaunch(
            of: launched,
            pairing: pairing,
            revalidatePairing: generation != operationGeneration
        )
    }

    func cleanupReturnedLaunch(
        of launched: RemoteSession,
        pairing: VerifiedPairing,
        revalidatePairing: Bool
    ) async {
        let cleanup = Task { @MainActor in
            await beginCleanup(
                of: launched,
                pairing: pairing.pairing,
                completionText: nil,
                verifiedPairing: revalidatePairing ? nil : pairing,
                allowsSupersededPairing: !revalidatePairing
            )
        }
        _ = await cleanup.value
    }

    func discardSessionForSupersededPairingIfNeeded(
        pairing verified: VerifiedPairing,
        generation: UInt64
    ) async {
        guard let activeSession = session else { return }
        await discardSessionForSupersededPairingIfNeeded(
            activeSession,
            pairing: verified,
            generation: generation
        )
    }

    func discardSessionForSupersededPairingIfNeeded(
        _ activeSession: RemoteSession,
        pairing verified: VerifiedPairing,
        generation: UInt64
    ) async {
        guard generation == operationGeneration,
              !Task.isCancelled,
              !isVerifiedPairingCurrent(verified),
              session?.id == activeSession.id else { return }
        abandonSession()
        pairing = nil
        await cleanupReturnedLaunch(
            of: activeSession,
            pairing: verified,
            revalidatePairing: false
        )
        guard generation == operationGeneration,
              !Task.isCancelled else { return }
        retriesPolling = false
        if pendingCleanup == nil {
            isBusy = false
            canRetry = false
        }
    }

    @discardableResult
    // swiftlint:disable:next function_body_length
    func beginCleanup(
        of sessionToClean: RemoteSession,
        pairing knownPairing: DaemonPairing?,
        completionText: String?,
        verifiedPairing: VerifiedPairing? = nil,
        allowsSupersededPairing: Bool = false
    ) async -> Bool {
        let generation = operationGeneration
        let retainedRetryContext = retryPrompt.map {
            (
                prompt: $0,
                projectRoot: retryProjectRoot,
                familiarID: retryFamiliarID,
                familiarPresentation: retryFamiliarPresentation
            )
        }
        defer {
            if generation == operationGeneration, let retainedRetryContext {
                retryPrompt = retainedRetryContext.prompt
                retryProjectRoot = retainedRetryContext.projectRoot
                retryFamiliarID = retainedRetryContext.familiarID
                retryFamiliarPresentation = retainedRetryContext.familiarPresentation
            }
        }

        while let ownership = cleanupOwnership {
            let ownerResult = await joinCleanupOwnership(ownership)
            let ownerClearedPending = pendingCleanup?.id != ownership.sessionID
            if ownership.sessionID == sessionToClean.id {
                if ownerResult || ownerClearedPending {
                    settleCompletedCleanupIfCurrent(
                        generation: generation,
                        message: completionText
                    )
                    return true
                }
                guard ownership.generation != generation,
                      generation == operationGeneration,
                      !Task.isCancelled else { return false }
                continue
            }
            guard ownerClearedPending,
                  generation == operationGeneration,
                  !Task.isCancelled else { return false }
        }

        guard pendingCleanup == nil
                || pendingCleanup?.id == sessionToClean.id else { return false }
        pendingCleanup = sessionToClean
        if let knownPairing {
            pendingCleanupPairing = knownPairing
        }
        pendingCleanupCompletionText = completionText
        isBusy = true
        canRetry = false
        retriesPolling = false

        let ownershipToken = claimCleanupOwnership(
            sessionID: sessionToClean.id,
            generation: generation
        )
        var result = false
        defer {
            finishCleanupOwnership(
                token: ownershipToken,
                result: result
            )
        }

        let request = CompanionCleanupRequest(
            session: sessionToClean,
            generation: generation,
            completionText: completionText,
            ownershipToken: ownershipToken
        )
        let authority = verifiedPairing.map {
            CompanionCleanupAuthority(
                verifiedPairing: $0,
                allowsSupersededPairing: allowsSupersededPairing
            )
        }
        result = await performOwnedCleanup(
            request,
            authority: authority
        )
        return result
    }

    private func performOwnedCleanup(
        _ request: CompanionCleanupRequest,
        authority suppliedAuthority: CompanionCleanupAuthority?
    ) async -> Bool {
        guard let authority = await resolveCleanupAuthority(
            suppliedAuthority,
            request: request
        ) else { return false }

        guard isCurrentCleanupOwnership(
            sessionID: request.session.id,
            token: request.ownershipToken
        ), pendingCleanup?.id == request.session.id else { return false }
        guard canStartCleanupKill(
            request,
            authority: authority
        ) else { return false }
        do {
            try await client.kill(
                pairing: authority.verifiedPairing.pairing,
                sessionID: request.session.id
            )
            guard isCurrentCleanupOwnership(
                sessionID: request.session.id,
                token: request.ownershipToken
            ), pendingCleanup?.id == request.session.id else { return false }
            completeCleanup(
                of: request.session,
                message: request.completionText,
                generation: request.generation
            )
            return true
        } catch {
            return handleCleanupFailure(
                error,
                request: request,
                authority: authority
            )
        }
    }

    private func canStartCleanupKill(
        _ request: CompanionCleanupRequest,
        authority: CompanionCleanupAuthority
    ) -> Bool {
        guard isCurrentCleanupOwnership(
            sessionID: request.session.id,
            token: request.ownershipToken
        ), pendingCleanup?.id == request.session.id else { return false }
        guard request.generation == operationGeneration,
              !Task.isCancelled else {
            if request.generation == operationGeneration {
                isBusy = false
                canRetry = true
            }
            return false
        }
        guard authority.allowsSupersededPairing
                || isVerifiedPairingCurrent(authority.verifiedPairing) else {
            isBusy = false
            canRetry = true
            return false
        }
        return true
    }

    private func handleCleanupFailure(
        _ error: Error,
        request: CompanionCleanupRequest,
        authority: CompanionCleanupAuthority
    ) -> Bool {
        guard isCurrentCleanupOwnership(
            sessionID: request.session.id,
            token: request.ownershipToken
        ), pendingCleanup?.id == request.session.id else { return false }
        if Self.isSessionNotLive(error) {
            completeCleanup(
                of: request.session,
                message: request.completionText ?? "Session already stopped.",
                generation: request.generation
            )
            return true
        }
        guard request.generation == operationGeneration else {
            return false
        }
        guard authority.allowsSupersededPairing
                || isVerifiedPairingCurrent(authority.verifiedPairing) else {
            isBusy = false
            canRetry = true
            return false
        }
        isBusy = false
        fail(error.localizedDescription, retryPrompt: nil)
        canRetry = true
        return false
    }

    private func resolveCleanupAuthority(
        _ suppliedAuthority: CompanionCleanupAuthority?,
        request: CompanionCleanupRequest
    ) async -> CompanionCleanupAuthority? {
        if let suppliedAuthority {
            guard isCurrentCleanupOwnership(
                sessionID: request.session.id,
                token: request.ownershipToken
            ), pendingCleanup?.id == request.session.id else { return nil }
            guard suppliedAuthority.allowsSupersededPairing
                    || isVerifiedPairingCurrent(
                        suppliedAuthority.verifiedPairing
                    ) else {
                isBusy = false
                canRetry = true
                return nil
            }
            return suppliedAuthority
        }
        guard let verifiedPairing = await cleanupPairing(
            generation: request.generation,
            session: request.session,
            completionText: request.completionText,
            ownershipToken: request.ownershipToken
        ) else { return nil }
        return CompanionCleanupAuthority(
            verifiedPairing: verifiedPairing,
            allowsSupersededPairing: false
        )
    }

    func cleanupPairing(
        generation: UInt64,
        session: RemoteSession,
        completionText: String?,
        ownershipToken: UInt64? = nil
    ) async -> VerifiedPairing? {
        guard generation == operationGeneration,
              cleanupContextIsCurrent(
                  sessionID: session.id,
                  ownershipToken: ownershipToken
              ),
              !Task.isCancelled else { return nil }
        guard let result = await availabilityGate(
            while: {
                generation == operationGeneration
                    && cleanupContextIsCurrent(
                        sessionID: session.id,
                        ownershipToken: ownershipToken
                    )
            }
        ) else {
            guard generation == operationGeneration,
                  cleanupContextIsCurrent(
                      sessionID: session.id,
                      ownershipToken: ownershipToken
                  ) else { return nil }
            isBusy = false
            canRetry = true
            return nil
        }
        guard generation == operationGeneration,
              cleanupContextIsCurrent(
                  sessionID: session.id,
                  ownershipToken: ownershipToken
              ),
              !Task.isCancelled else { return nil }
        guard let verified = verifiedCleanupPairing(
            from: result.gate,
            availabilityGeneration: result.availabilityGeneration
        ) else { return nil }
        return validateCleanupPairing(
            verified,
            session: session,
            completionText: completionText,
            generation: generation
        )
    }

    func verifiedCleanupPairing(
        from gate: CompanionModel.SessionGate,
        availabilityGeneration: UInt64
    ) -> VerifiedPairing? {
        switch gate {
        case let .ready(pairing):
            return VerifiedPairing(
                pairing: pairing,
                availabilityGeneration: availabilityGeneration
            )
        case .notPaired:
            isBusy = false
            fail(
                "Not paired. Pair with a daemon in the Companion tab first.",
                retryPrompt: nil
            )
            canRetry = true
            return nil
        case let .blocked(reason, hint):
            isBusy = false
            fail("\(reason). \(hint)", retryPrompt: nil)
            canRetry = true
            return nil
        }
    }

    func validateCleanupPairing(
        _ verified: VerifiedPairing,
        session: RemoteSession,
        completionText: String?,
        generation: UInt64
    ) -> VerifiedPairing? {
        guard isVerifiedPairingCurrent(verified) else {
            isBusy = false
            canRetry = true
            return nil
        }
        guard let expected = pendingCleanupPairing else { return verified }
        guard Self.isSameDaemonEndpoint(
            expected,
            verified.pairing
        ) else {
            isBusy = false
            fail(
                "The pending session belongs to a different paired daemon. "
                    + "Re-pair with that daemon to retry cleanup.",
                retryPrompt: nil
            )
            canRetry = true
            return nil
        }
        guard Self.isSameDaemonInstance(
            expected,
            verified.pairing
        ) else {
            completeCleanup(
                of: session,
                message: completionText,
                generation: generation
            )
            return nil
        }
        return verified
    }

    func claimCleanupOwnership(
        sessionID: String,
        generation: UInt64
    ) -> UInt64 {
        nextCleanupOwnershipToken &+= 1
        let token = nextCleanupOwnershipToken
        cleanupOwnership = CompanionCleanupOwnership(
            sessionID: sessionID,
            generation: generation,
            token: token
        )
        return token
    }

    func joinCleanupOwnership(
        _ ownership: CompanionCleanupOwnership
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            guard var current = cleanupOwnership,
                  current.sessionID == ownership.sessionID,
                  current.token == ownership.token else {
                continuation.resume(
                    returning: pendingCleanup?.id != ownership.sessionID
                )
                return
            }
            current.waiters.append(continuation)
            cleanupOwnership = current
        }
    }

    func finishCleanupOwnership(token: UInt64, result: Bool) {
        guard let ownership = cleanupOwnership,
              ownership.token == token else { return }
        cleanupOwnership = nil
        ownership.waiters.forEach { $0.resume(returning: result) }
    }

    func isCurrentCleanupOwnership(
        sessionID: String,
        token: UInt64
    ) -> Bool {
        cleanupOwnership?.sessionID == sessionID
            && cleanupOwnership?.token == token
    }

    func cleanupContextIsCurrent(
        sessionID: String,
        ownershipToken: UInt64?
    ) -> Bool {
        guard let ownershipToken else { return true }
        return isCurrentCleanupOwnership(
            sessionID: sessionID,
            token: ownershipToken
        ) && pendingCleanup?.id == sessionID
    }

    func completeCleanup(
        of cleanedSession: RemoteSession,
        message: String?,
        generation: UInt64
    ) {
        guard pendingCleanup?.id == cleanedSession.id else { return }
        pendingCleanup = nil
        pendingCleanupPairing = nil
        pendingCleanupCompletionText = nil
        settleCompletedCleanupIfCurrent(
            generation: generation,
            message: message
        )
    }

    func settleCompletedCleanupIfCurrent(
        generation: UInt64,
        message: String?
    ) {
        guard generation == operationGeneration,
              session == nil else { return }
        isBusy = false
        canRetry = false
        if let message {
            items.append(ChatItem(kind: .status, text: message))
        }
    }

    func fail(_ message: String, retryPrompt: String?) {
        items.append(ChatItem(kind: .error, text: message))
        self.retryPrompt = retryPrompt
        canRetry = retryPrompt != nil
    }

    static func title(from prompt: String) -> String {
        let firstLine = prompt.split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? "Claude session"
        return String(firstLine.prefix(80))
    }

    static func chatItems(from remote: [RemoteTranscriptItem]) -> [ChatItem] {
        remote.map { item in
            let id = "remote-\(item.id)"
            switch item.role {
            case .user:
                return ChatItem(id: id, kind: .user, text: item.text)
            case .assistant:
                return ChatItem(id: id, kind: .assistant, text: item.text)
            case .terminal:
                return ChatItem(id: id, kind: .status, text: item.text)
            case .status:
                return ChatItem(id: id, kind: .status, text: item.text)
            case let .tool(isError):
                return ChatItem(
                    id: id,
                    kind: .tool,
                    text: "Tool result",
                    tool: ToolCallInfo(
                        toolId: id,
                        name: "Tool result",
                        inputSummary: "",
                        result: item.text,
                        isError: isError,
                        isRunning: false
                    )
                )
            }
        }
    }

    static func isSessionNotLive(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("session is not live")
            || message.contains("session is not running")
            || message.contains("session_not_live")
            || message.contains("session was not found")
            || message.contains("session_not_found")
    }

    static func isSameDaemonEndpoint(
        _ lhs: DaemonPairing,
        _ rhs: DaemonPairing
    ) -> Bool {
        lhs.host == rhs.host && lhs.port == rhs.port
    }

    static func isSameDaemonInstance(
        _ lhs: DaemonPairing,
        _ rhs: DaemonPairing
    ) -> Bool {
        isSameDaemonEndpoint(lhs, rhs)
            && lhs.pid == rhs.pid
            && lhs.startedAt == rhs.startedAt
    }

    static func isAbsoluteHostPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/")
            || trimmed.range(
                of: #"^[A-Za-z]:[\\/]"#,
                options: .regularExpression
            ) != nil
    }

    static func normalizedFamiliarID(_ familiarID: String?) -> String? {
        guard let familiarID else { return nil }
        let normalized = familiarID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
