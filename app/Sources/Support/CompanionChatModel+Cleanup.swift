import Foundation

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
        pendingCleanup = sessionToClean
        if let knownPairing {
            pendingCleanupPairing = knownPairing
        }
        pendingCleanupCompletionText = completionText
        isBusy = true
        canRetry = false
        retriesPolling = false

        guard let verified = await resolveCleanupPairing(
            verifiedPairing,
            generation: generation,
            session: sessionToClean,
            completionText: completionText
        ) else { return false }

        guard canStartCleanupKill(generation: generation) else { return false }
        guard cleanupKillInFlightSessionID == nil else { return false }
        cleanupKillInFlightSessionID = sessionToClean.id
        defer { cleanupKillInFlightSessionID = nil }
        do {
            try await client.kill(pairing: verified, sessionID: sessionToClean.id)
            guard pendingCleanup?.id == sessionToClean.id else { return false }
            completeCleanup(of: sessionToClean, message: completionText)
            return true
        } catch {
            return handleCleanupFailure(
                error,
                session: sessionToClean,
                completionText: completionText,
                generation: generation
            )
        }
    }

    func canStartCleanupKill(generation: UInt64) -> Bool {
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
        generation: UInt64
    ) -> Bool {
        guard pendingCleanup?.id == session.id else { return false }
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
        completionText: String?
    ) async -> DaemonPairing? {
        if let verifiedPairing {
            return verifiedPairing
        }
        return await cleanupPairing(
            generation: generation,
            session: session,
            completionText: completionText
        )
    }

    func cleanupPairing(
        generation: UInt64,
        session: RemoteSession,
        completionText: String?
    ) async -> DaemonPairing? {
        guard let verified = await verifiedPairing(
            reportFailure: true,
            generation: generation
        ) else {
            guard generation == operationGeneration else { return nil }
            isBusy = false
            canRetry = true
            return nil
        }
        guard generation == operationGeneration else { return nil }
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
