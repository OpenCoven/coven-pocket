import Foundation

/// One rendered row of a remote session transcript.
struct RemoteTranscriptItem: Identifiable, Equatable {
    struct Identity: Hashable, CustomStringConvertible {
        let eventSequence: Int64
        let ordinal: Int

        var description: String {
            "\(eventSequence)-\(ordinal)"
        }
    }

    enum Role: Equatable {
        case user
        case assistant
        case tool(isError: Bool)
        case terminal
        case status
    }

    let id: Identity
    let role: Role
    let text: String

    init(id: Int64, role: Role, text: String) {
        self.init(
            identity: Identity(eventSequence: id, ordinal: 0),
            role: role,
            text: text
        )
    }

    init(identity: Identity, role: Role, text: String) {
        id = identity
        self.role = role
        self.text = text
    }
}

/// Pure mapping from daemon event rows to transcript items. Static so
/// tests can drive it with fixture payloads; no networking in here.
enum RemoteTranscript {
    enum ResultSemantics: Equatable {
        case session
        case turn
    }

    enum AttachmentMode: Equatable {
        case unknown
        case pty
        case stream
    }

    struct Snapshot {
        let items: [RemoteTranscriptItem]
        let latestResultSeq: Int64?
        let sessionEnded: Bool
        let attachmentMode: AttachmentMode

        var isStreamSession: Bool {
            attachmentMode == .stream
        }
    }

    /// Build display items from the full accumulated event list.
    /// Consecutive `output` frames merge into one terminal block, since
    /// PTY chunk boundaries are arbitrary.
    static func items(
        from events: [RemoteEvent],
        resultSemantics: ResultSemantics = .session
    ) -> [RemoteTranscriptItem] {
        snapshot(from: events, resultSemantics: resultSemantics).items
    }

    /// Decode daemon ledger rows into display items and completion state.
    /// Stream sessions store raw JSONL stdout in `output.payload.data`;
    /// arbitrary read boundaries can split one JSON frame across rows.
    static func snapshot(
        from events: [RemoteEvent],
        resultSemantics: ResultSemantics = .session
    ) -> Snapshot {
        var decoder = RemoteTranscriptDecoder(resultSemantics: resultSemantics)
        for event in events {
            decoder.decode(event)
        }
        return Snapshot(
            items: decoder.items,
            latestResultSeq: decoder.latestResultSeq,
            sessionEnded: decoder.sessionEnded,
            attachmentMode: resultSemantics == .turn ? .stream : .pty
        )
    }

    static func attachmentSnapshot(from events: [RemoteEvent]) -> Snapshot {
        let mode = RemoteAttachmentClassifier.classify(events)
        let decoded = snapshot(
            from: events,
            resultSemantics: mode == .stream ? .turn : .session
        )
        return Snapshot(
            items: decoded.items,
            latestResultSeq: decoded.latestResultSeq,
            sessionEnded: decoded.sessionEnded,
            attachmentMode: mode
        )
    }

    /// Detect a pending approval prompt in the tail of terminal output.
    /// Harness prompts vary; this looks for the common ask-shapes so the
    /// app can offer one-tap approve/deny. Forwarding is plain input, so
    /// a missed prompt can always be answered from the keyboard.
    static func approvalPrompt(in items: [RemoteTranscriptItem]) -> String? {
        guard let last = items.last, last.role == .terminal else { return nil }
        let lines = last.text.suffix(600)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(6)
        for line in lines.reversed() {
            let lower = line.lowercased()
            let asksYesNo = lower.contains("y/n") || lower.contains("yes/no")
            let asksPermission = lower.hasSuffix("?")
                && (lower.contains("allow") || lower.contains("approve")
                    || lower.contains("proceed") || lower.contains("continue"))
            if asksYesNo || asksPermission {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Strip ANSI escapes and apply carriage-return semantics so raw PTY
    /// text reads as plain lines.
    static func cleanTerminalText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[@-~]", with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\u{1B}.", with: "", options: .regularExpression
        )
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        }
        return lines.joined(separator: "\n")
    }

}
