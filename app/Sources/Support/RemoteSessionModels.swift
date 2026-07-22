import Foundation

/// Session list + live attach state for the paired daemon.
///
/// All traffic gates on `CompanionModel.gateForSessionTraffic()` — the
/// mandatory handshake re-check — before touching session routes.
@MainActor
final class RemoteSessionsModel: ObservableObject {
    enum ListState: Equatable {
        case idle
        case loading
        case loaded
        case blocked(reason: String, hint: String)
    }

    @Published private(set) var sessions: [RemoteSession] = []
    @Published private(set) var state: ListState = .idle

    let companion: CompanionModel

    static let requestTimeoutMs: UInt32 = 6000

    init(companion: CompanionModel) {
        self.companion = companion
    }

    func refresh() async {
        if state == .idle { state = .loading }
        switch await companion.gateForSessionTraffic() {
        case .notPaired:
            state = .blocked(
                reason: "Not paired",
                hint: "Pair with a daemon in the Companion tab first."
            )
        case let .blocked(reason, hint):
            state = .blocked(reason: reason, hint: hint)
        case let .ready(pairing):
            do {
                sessions = try await companion.engine.remoteSessions(
                    host: pairing.host, port: pairing.port,
                    timeoutMs: Self.requestTimeoutMs
                )
                state = .loaded
            } catch {
                state = .blocked(
                    reason: "Could not list sessions",
                    hint: error.localizedDescription
                )
            }
        }
    }
}

/// Live attachment to one remote session: polls the event ledger, renders
/// a transcript, forwards input, and surfaces approval prompts.
@MainActor
final class RemoteAttachModel: ObservableObject {
    @Published private(set) var items: [RemoteTranscriptItem] = []
    @Published private(set) var approvalPrompt: String?
    @Published private(set) var finished = false
    @Published private(set) var errorText: String?
    @Published var draft = ""

    let session: RemoteSession

    private let engine: PocketEngine
    private let host: String
    private let port: UInt16
    private var events: [RemoteEvent] = []
    private var cursor: Int64 = 0

    static let pollInterval: Duration = .seconds(2)
    static let pageLimit: UInt32 = 200
    static let requestTimeoutMs: UInt32 = 6000

    init(session: RemoteSession, pairing: DaemonPairing, engine: PocketEngine) {
        self.session = session
        self.host = pairing.host
        self.port = pairing.port
        self.engine = engine
    }

    /// Poll until the owning view disappears (task cancellation) or the
    /// session finishes and the ledger has drained.
    func attach() async {
        while !Task.isCancelled {
            await refreshOnce()
            if finished { break }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// One poll: drain available pages, then re-derive the view state.
    func refreshOnce() async {
        do {
            var hasMore = true
            while hasMore && !Task.isCancelled {
                let page = try await engine.remoteEvents(
                    host: host, port: port, sessionId: session.id,
                    afterSeq: cursor, limit: Self.pageLimit,
                    timeoutMs: Self.requestTimeoutMs
                )
                events.append(contentsOf: page.events)
                cursor = page.nextAfterSeq
                hasMore = page.hasMore
            }
            errorText = nil
            apply(events: events)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Pure state derivation, split out so tests can drive it directly.
    func apply(events: [RemoteEvent]) {
        items = RemoteTranscript.items(from: events)
        approvalPrompt = RemoteTranscript.approvalPrompt(in: items)
        finished = events.contains { $0.kind == "result" }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        await forward(text + "\n")
    }

    func approve() async { await forward("y\n") }
    func deny() async { await forward("n\n") }

    func kill() async {
        do {
            try await engine.remoteKill(
                host: host, port: port, sessionId: session.id,
                timeoutMs: Self.requestTimeoutMs
            )
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func forward(_ data: String) async {
        do {
            try await engine.remoteSendInput(
                host: host, port: port, sessionId: session.id, data: data,
                timeoutMs: Self.requestTimeoutMs
            )
            errorText = nil
            approvalPrompt = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
