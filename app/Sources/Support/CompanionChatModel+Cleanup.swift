import Foundation

// swiftlint:disable file_length

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
        pairing: DaemonPairing,
        generation: UInt64
    ) async -> Bool {
        let operationInvalidated = generation != operationGeneration
        guard operationInvalidated || Task.isCancelled else { return false }
        await cleanupReturnedLaunch(
            of: launched,
            pairing: pairing,
            revalidatePairing: operationInvalidated
        )
        if Task.isCancelled {
            finishCancelledSend(generation: generation)
        }
        return true
    }

    func finishInvalidatedSendIfNeeded(
        generation: UInt64,
        pairing: DaemonPairing,
        launchedSession: RemoteSession?
    ) async -> Bool {
        guard generation != operationGeneration
                || Task.isCancelled else { return false }
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

    func finalizeSend(
        _ verified: DaemonPairing,
        generation: UInt64,
        launchedSession: RemoteSession?
    ) async {
        pairing = verified
        startPolling()
        _ = await finishPollingIfCancelled(
            generation: generation,
            pairing: verified,
            launchedSession: launchedSession
        )
    }

    func finishPollingIfCancelled(
        generation: UInt64,
        pairing: DaemonPairing,
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
        pairing: DaemonPairing,
        generation: UInt64
    ) async {
        if session?.id == launched.id {
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
        pairing: DaemonPairing,
        revalidatePairing: Bool
    ) async {
        let cleanup = Task { @MainActor in
            await beginCleanup(
                of: launched,
                pairing: pairing,
                completionText: nil,
                verifiedPairing: revalidatePairing ? nil : pairing
            )
        }
        _ = await cleanup.value
    }

    @discardableResult
    // swiftlint:disable:next function_body_length
    func beginCleanup(
        of sessionToClean: RemoteSession,
        pairing knownPairing: DaemonPairing?,
        completionText: String?,
        verifiedPairing: DaemonPairing? = nil
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

        result = await performOwnedCleanup(
            of: sessionToClean,
            verifiedPairing: verifiedPairing,
            generation: generation,
            completionText: completionText,
            ownershipToken: ownershipToken
        )
        return result
    }

    func performOwnedCleanup(
        of sessionToClean: RemoteSession,
        verifiedPairing: DaemonPairing?,
        generation: UInt64,
        completionText: String?,
        ownershipToken: UInt64
    ) async -> Bool {
        guard let verified = await resolveCleanupPairing(
            verifiedPairing,
            generation: generation,
            session: sessionToClean,
            completionText: completionText,
            ownershipToken: ownershipToken
        ) else { return false }

        guard isCurrentCleanupOwnership(
            sessionID: sessionToClean.id,
            token: ownershipToken
        ), pendingCleanup?.id == sessionToClean.id else { return false }
        guard canStartCleanupKill(
            generation: generation,
            sessionID: sessionToClean.id,
            ownershipToken: ownershipToken
        ) else { return false }
        do {
            try await client.kill(pairing: verified, sessionID: sessionToClean.id)
            guard isCurrentCleanupOwnership(
                sessionID: sessionToClean.id,
                token: ownershipToken
            ), pendingCleanup?.id == sessionToClean.id else { return false }
            completeCleanup(of: sessionToClean, message: completionText)
            return true
        } catch {
            return handleCleanupFailure(
                error,
                session: sessionToClean,
                completionText: completionText,
                generation: generation,
                ownershipToken: ownershipToken
            )
        }
    }

    func canStartCleanupKill(
        generation: UInt64,
        sessionID: String,
        ownershipToken: UInt64
    ) -> Bool {
        guard isCurrentCleanupOwnership(
            sessionID: sessionID,
            token: ownershipToken
        ), pendingCleanup?.id == sessionID else { return false }
        guard generation == operationGeneration,
              !Task.isCancelled else {
            if generation == operationGeneration {
                isBusy = false
                canRetry = true
            }
            return false
        }
        return true
    }

    func handleCleanupFailure(
        _ error: Error,
        session: RemoteSession,
        completionText: String?,
        generation: UInt64,
        ownershipToken: UInt64
    ) -> Bool {
        guard isCurrentCleanupOwnership(
            sessionID: session.id,
            token: ownershipToken
        ), pendingCleanup?.id == session.id else { return false }
        if Self.isSessionNotLive(error) {
            completeCleanup(
                of: session,
                message: completionText ?? "Session already stopped."
            )
            return true
        }
        guard generation == operationGeneration else {
            isBusy = false
            canRetry = true
            return false
        }
        isBusy = false
        fail(error.localizedDescription, retryPrompt: nil)
        canRetry = true
        return false
    }

    func resolveCleanupPairing(
        _ verifiedPairing: DaemonPairing?,
        generation: UInt64,
        session: RemoteSession,
        completionText: String?,
        ownershipToken: UInt64
    ) async -> DaemonPairing? {
        if let verifiedPairing {
            guard isCurrentCleanupOwnership(
                sessionID: session.id,
                token: ownershipToken
            ), pendingCleanup?.id == session.id else { return nil }
            return verifiedPairing
        }
        return await cleanupPairing(
            generation: generation,
            session: session,
            completionText: completionText,
            ownershipToken: ownershipToken
        )
    }

    // swiftlint:disable:next function_body_length
    func cleanupPairing(
        generation: UInt64,
        session: RemoteSession,
        completionText: String?,
        ownershipToken: UInt64? = nil
    ) async -> DaemonPairing? {
        guard generation == operationGeneration,
              cleanupContextIsCurrent(
                  sessionID: session.id,
                  ownershipToken: ownershipToken
              ),
              !Task.isCancelled else { return nil }
        guard let gate = await availabilityGate(
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
        let verified: DaemonPairing
        switch gate {
        case let .ready(pairing):
            verified = pairing
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
        guard let expected = pendingCleanupPairing else { return verified }
        guard Self.isSameDaemonEndpoint(expected, verified) else {
            isBusy = false
            fail(
                "The pending session belongs to a different paired daemon. "
                    + "Re-pair with that daemon to retry cleanup.",
                retryPrompt: nil
            )
            canRetry = true
            return nil
        }
        guard Self.isSameDaemonInstance(expected, verified) else {
            completeCleanup(of: session, message: completionText)
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

    func completeCleanup(of cleanedSession: RemoteSession, message: String?) {
        guard pendingCleanup?.id == cleanedSession.id else { return }
        pendingCleanup = nil
        pendingCleanupPairing = nil
        pendingCleanupCompletionText = nil
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
