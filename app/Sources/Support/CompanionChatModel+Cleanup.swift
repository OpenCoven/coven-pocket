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

    func beginCleanup(
        of sessionToClean: RemoteSession,
        pairing knownPairing: DaemonPairing?,
        completionText: String?
    ) async {
        pendingCleanup = sessionToClean
        if let knownPairing {
            pendingCleanupPairing = knownPairing
        }
        pendingCleanupCompletionText = completionText
        isBusy = true
        canRetry = false
        retriesPolling = false
        retryPrompt = nil
        let generation = operationGeneration

        guard let verified = await cleanupPairing(
            generation: generation,
            session: sessionToClean,
            completionText: completionText
        ) else { return }

        do {
            try await client.kill(pairing: verified, sessionID: sessionToClean.id)
            guard generation == operationGeneration else { return }
            completeCleanup(of: sessionToClean, message: completionText)
        } catch {
            guard generation == operationGeneration else { return }
            if Self.isSessionNotLive(error) {
                completeCleanup(
                    of: sessionToClean,
                    message: completionText ?? "Session already stopped."
                )
                return
            }
            isBusy = false
            fail(error.localizedDescription, retryPrompt: nil)
            canRetry = true
        }
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
}
