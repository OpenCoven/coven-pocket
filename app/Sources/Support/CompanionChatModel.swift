import Foundation

@MainActor
final class CompanionChatModel: ObservableObject {
    enum Availability: Equatable {
        case checking
        case ready(DaemonPairing)
        case blocked(reason: String, hint: String)
    }

    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var isBusy = false
    @Published private(set) var canRetry = false
    @Published private(set) var approvalPrompt: String?
    @Published private(set) var availability: Availability = .checking

    private(set) var cursor: Int64 = 0

    static let requestTimeoutMs: UInt32 = 6_000
    static let pageLimit: UInt32 = 200
    static let pollInterval: Duration = .seconds(2)

    let companion: CompanionModel
    private let client: any CompanionSessionClient
    private var pairing: DaemonPairing?
    private var session: RemoteSession?
    private var accumulatedEvents: [RemoteEvent] = []
    private var retryPrompt: String?
    private var retryProjectRoot = ""
    private var pollTask: Task<Void, Never>?
    private var lastCompletedResultSeq: Int64 = 0
    private var initialPrompt: String?
    private var retriesPolling = false

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

    func refreshAvailability() async {
        availability = Self.availability(from: await client.sessionGate())
    }

    func send(prompt: String, projectRoot: String) async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !isBusy else { return }
        guard Self.isAbsoluteHostPath(trimmedRoot) else {
            fail(
                "Enter an absolute project path on the daemon host.",
                retryPrompt: nil
            )
            return
        }
        retryProjectRoot = trimmedRoot
        guard let verified = await verifiedPairing(reportFailure: true) else {
            retryPrompt = trimmedPrompt
            canRetry = true
            return
        }

        isBusy = true
        canRetry = false
        retryPrompt = nil
        retriesPolling = false
        do {
            if let session {
                try await client.sendInput(
                    pairing: verified,
                    sessionID: session.id,
                    data: trimmedPrompt
                )
            } else {
                prepareForNewSession()
                session = try await client.launch(
                    pairing: verified,
                    projectRoot: trimmedRoot,
                    prompt: trimmedPrompt,
                    title: Self.title(from: trimmedPrompt)
                )
                initialPrompt = trimmedPrompt
                items = [ChatItem(kind: .user, text: trimmedPrompt)]
            }
            pairing = verified
            startPolling()
        } catch {
            isBusy = false
            fail(error.localizedDescription, retryPrompt: trimmedPrompt)
        }
    }

    func retry() async {
        guard !isBusy else { return }
        if retriesPolling {
            guard let verified = await verifiedPairing(reportFailure: true) else {
                canRetry = true
                return
            }
            pairing = verified
            retriesPolling = false
            canRetry = false
            isBusy = true
            await refreshOnce()
            if !retriesPolling {
                startPolling()
            }
            return
        }
        guard let prompt = retryPrompt else { return }
        retryPrompt = nil
        await send(prompt: prompt, projectRoot: retryProjectRoot)
    }

    func refreshOnce() async {
        guard let pairing, let session else { return }
        do {
            var hasMore = true
            while hasMore && !Task.isCancelled {
                let page = try await client.events(
                    pairing: pairing,
                    sessionID: session.id,
                    afterSeq: cursor
                )
                let knownSequences = Set(accumulatedEvents.map(\.seq))
                accumulatedEvents.append(
                    contentsOf: page.events.filter { !knownSequences.contains($0.seq) }
                )
                cursor = max(cursor, page.nextAfterSeq)
                hasMore = page.hasMore
            }
            apply(events: accumulatedEvents)
        } catch {
            items.append(ChatItem(kind: .error, text: error.localizedDescription))
            pollTask?.cancel()
            pollTask = nil
            isBusy = false
            if error.localizedDescription.localizedCaseInsensitiveContains(
                "session is not live"
            ) {
                self.session = nil
                retriesPolling = false
                canRetry = false
            } else {
                retriesPolling = true
                canRetry = true
            }
        }
    }

    func apply(events: [RemoteEvent]) {
        accumulatedEvents = events
        cursor = max(cursor, events.map(\.seq).max() ?? cursor)
        let remoteItems = RemoteTranscript.items(
            from: events,
            resultSemantics: .turn
        )
        items = Self.chatItems(from: remoteItems)
        if let initialPrompt {
            items.insert(ChatItem(kind: .user, text: initialPrompt), at: 0)
        }
        approvalPrompt = RemoteTranscript.approvalPrompt(in: remoteItems)

        if let newestResult = events
            .filter({ $0.kind == "result" })
            .map(\.seq)
            .max(),
           newestResult > lastCompletedResultSeq {
            lastCompletedResultSeq = newestResult
            isBusy = false
        }
    }

    func approve() async {
        await sendControl("y\n")
    }

    func deny() async {
        await sendControl("n\n")
    }

    func stop() async {
        guard let session, let verified = await verifiedPairing(reportFailure: true) else {
            return
        }
        do {
            try await client.kill(pairing: verified, sessionID: session.id)
            pollTask?.cancel()
            pollTask = nil
            self.session = nil
            isBusy = false
            canRetry = false
            retriesPolling = false
            approvalPrompt = nil
            items.append(ChatItem(kind: .status, text: "Stopped."))
        } catch {
            items.append(ChatItem(kind: .error, text: error.localizedDescription))
        }
    }

    func reset() async {
        if let session,
           let verified = await verifiedPairing(reportFailure: false) {
            try? await client.kill(pairing: verified, sessionID: session.id)
        }
        pollTask?.cancel()
        pollTask = nil
        pairing = nil
        session = nil
        accumulatedEvents = []
        cursor = 0
        lastCompletedResultSeq = 0
        initialPrompt = nil
        retriesPolling = false
        retryPrompt = nil
        retryProjectRoot = ""
        items = []
        approvalPrompt = nil
        isBusy = false
        canRetry = false
    }
}

private extension CompanionChatModel {
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

    func verifiedPairing(reportFailure: Bool) async -> DaemonPairing? {
        let gate = await client.sessionGate()
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

    func sendControl(_ data: String) async {
        guard let session,
              let verified = await verifiedPairing(reportFailure: true) else {
            return
        }
        do {
            try await client.sendInput(
                pairing: verified,
                sessionID: session.id,
                data: data
            )
            approvalPrompt = nil
        } catch {
            items.append(ChatItem(kind: .error, text: error.localizedDescription))
        }
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
        retriesPolling = false
        items = []
        approvalPrompt = nil
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
            switch item.role {
            case .user:
                return ChatItem(kind: .user, text: item.text)
            case .assistant:
                return ChatItem(kind: .assistant, text: item.text)
            case .terminal:
                return ChatItem(kind: .status, text: item.text)
            case .status:
                return ChatItem(kind: .status, text: item.text)
            case let .tool(isError):
                return ChatItem(
                    kind: .tool,
                    text: "Tool result",
                    tool: ToolCallInfo(
                        toolId: "remote-\(item.id)",
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
}

extension CompanionChatModel {
    static func isAbsoluteHostPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/")
            || trimmed.range(
                of: #"^[A-Za-z]:[\\/]"#,
                options: .regularExpression
            ) != nil
    }
}
