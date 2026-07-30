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
///
/// Attach and every user-initiated action re-run the pairing gate; the
/// poll loop reuses the pairing from the most recent successful gate.
@MainActor
final class RemoteAttachModel: ObservableObject {
    @Published private(set) var items: [RemoteTranscriptItem] = []
    @Published private(set) var approvalPrompt: String?
    @Published private(set) var finished = false
    @Published private(set) var errorText: String?
    @Published var draft = ""

    let session: RemoteSession

    private let companion: CompanionModel
    private var pairing: DaemonPairing?
    private var events: [RemoteEvent] = []
    private var cursor: Int64 = 0
    private var attachmentMode: RemoteTranscript.AttachmentMode = .unknown

    private var engine: PocketEngine { companion.engine }

    var acceptsInput: Bool {
        !finished && attachmentMode != .unknown
    }

    static let pollInterval: Duration = .seconds(2)
    static let pageLimit: UInt32 = 200
    static let requestTimeoutMs: UInt32 = 6000

    init(session: RemoteSession, companion: CompanionModel) {
        self.session = session
        self.companion = companion
    }

    /// Poll until the owning view disappears (task cancellation) or the
    /// session finishes and the ledger has drained.
    func attach() async {
        guard await gate() != nil else { return }
        while !Task.isCancelled {
            await refreshOnce()
            if finished { break }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// One poll: drain available pages, then re-derive the view state.
    func refreshOnce() async {
        guard let pairing else { return }
        do {
            var hasMore = true
            while hasMore && !Task.isCancelled {
                let page = try await engine.remoteEvents(
                    host: pairing.host, port: pairing.port, sessionId: session.id,
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
        let snapshot = RemoteTranscript.attachmentSnapshot(from: events)
        attachmentMode = snapshot.attachmentMode
        items = snapshot.items
        approvalPrompt = attachmentMode != .pty
            ? nil
            : RemoteTranscript.approvalPrompt(in: items)
        finished = snapshot.sessionEnded
            || (attachmentMode == .pty && snapshot.latestResultSeq != nil)
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let data = Self.inputData(text, mode: attachmentMode) else {
            errorText = "Waiting for session output before enabling input."
            return
        }
        draft = ""
        await forward(data)
    }

    func approve() async {
        guard attachmentMode == .pty else { return }
        await forward("y\n")
    }

    func deny() async {
        guard attachmentMode == .pty else { return }
        await forward("n\n")
    }

    static func inputData(
        _ text: String,
        mode: RemoteTranscript.AttachmentMode
    ) -> String? {
        switch mode {
        case .unknown:
            return nil
        case .pty:
            return text + "\n"
        case .stream:
            return text
        }
    }

    func kill() async {
        guard let pairing = await gate() else { return }
        do {
            try await engine.remoteKill(
                host: pairing.host, port: pairing.port, sessionId: session.id,
                timeoutMs: Self.requestTimeoutMs
            )
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Re-run the mandatory pairing gate; publish the failure reason and
    /// return nil when session traffic must not proceed.
    private func gate() async -> DaemonPairing? {
        switch await companion.gateForSessionTraffic() {
        case let .ready(fresh):
            pairing = fresh
            return fresh
        case .notPaired:
            pairing = nil
            errorText = "Not paired — pair with a daemon in the Companion tab first."
            return nil
        case let .blocked(reason, hint):
            pairing = nil
            errorText = "\(reason). \(hint)"
            return nil
        }
    }

    private func forward(_ data: String) async {
        guard let pairing = await gate() else { return }
        do {
            try await engine.remoteSendInput(
                host: pairing.host, port: pairing.port, sessionId: session.id, data: data,
                timeoutMs: Self.requestTimeoutMs
            )
            errorText = nil
            approvalPrompt = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
