import Foundation

/// One rendered row of a remote session transcript.
struct RemoteTranscriptItem: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case tool(isError: Bool)
        case terminal
        case status
    }

    let id: Int64
    let role: Role
    let text: String
}

/// Pure mapping from daemon event rows to transcript items. Static so
/// tests can drive it with fixture payloads; no networking in here.
enum RemoteTranscript {
    enum ResultSemantics: Equatable {
        case session
        case turn
    }

    struct Snapshot {
        let items: [RemoteTranscriptItem]
        let latestResultSeq: Int64?
        let sessionEnded: Bool
    }

    private struct SnapshotAccumulator {
        var items: [RemoteTranscriptItem] = []
        var latestResultSeq: Int64?
        var sessionEnded = false
        var streamBuffer = ""
        var lastStreamEventSeq: Int64?
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
        var accumulator = SnapshotAccumulator()
        for event in events {
            guard let payload = parse(event.payloadJson) else { continue }
            appendEvent(
                event,
                payload: payload,
                resultSemantics: resultSemantics,
                accumulator: &accumulator
            )
        }
        return finish(accumulator, resultSemantics: resultSemantics)
    }
}

private extension RemoteTranscript {
    private static func appendEvent(
        _ event: RemoteEvent,
        payload: [String: Any],
        resultSemantics: ResultSemantics,
        accumulator: inout SnapshotAccumulator
    ) {
        if event.kind == "input" {
            append(
                &accumulator.items,
                id: event.seq,
                role: .user,
                text: payload["data"] as? String ?? ""
            )
            return
        }
        if appendSessionEnd(event, payload: payload, items: &accumulator.items) {
            accumulator.sessionEnded = true
            return
        }
        if event.kind == "output",
           let data = payload["data"] as? String {
            if resultSemantics == .turn {
                accumulator.lastStreamEventSeq = event.seq
                accumulator.streamBuffer.append(data)
                decodeStreamLines(
                    from: &accumulator.streamBuffer,
                    eventSeq: event.seq,
                    resultSemantics: resultSemantics,
                    items: &accumulator.items,
                    latestResultSeq: &accumulator.latestResultSeq
                )
            } else {
                appendTerminal(&accumulator.items, id: event.seq, text: data)
            }
            return
        }
        appendPayload(
            payload,
            eventSeq: event.seq,
            resultSemantics: resultSemantics,
            items: &accumulator.items,
            latestResultSeq: &accumulator.latestResultSeq
        )
    }

    private static func finish(
        _ accumulator: SnapshotAccumulator,
        resultSemantics: ResultSemantics
    ) -> Snapshot {
        var accumulator = accumulator
        if resultSemantics == .turn,
           let lastStreamEventSeq = accumulator.lastStreamEventSeq {
            decodeCompleteStreamTail(
                accumulator.streamBuffer,
                eventSeq: lastStreamEventSeq,
                resultSemantics: resultSemantics,
                items: &accumulator.items,
                latestResultSeq: &accumulator.latestResultSeq
            )
        }
        return Snapshot(
            items: accumulator.items,
            latestResultSeq: accumulator.latestResultSeq,
            sessionEnded: accumulator.sessionEnded
        )
    }

    static func appendSessionEnd(
        _ event: RemoteEvent,
        payload: [String: Any],
        items: inout [RemoteTranscriptItem]
    ) -> Bool {
        guard event.kind == "exit" || event.kind == "kill" else { return false }
        let status = payload["status"] as? String
        append(
            &items,
            id: event.seq,
            role: .status,
            text: event.kind == "kill"
                ? "Session stopped"
                : "Session \(status ?? "ended")"
        )
        return true
    }

    private static func decodeStreamLines(
        from buffer: inout String,
        eventSeq: Int64,
        resultSemantics: ResultSemantics,
        items: inout [RemoteTranscriptItem],
        latestResultSeq: inout Int64?
    ) {
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty, let payload = parse(line) else { continue }
            appendPayload(
                payload,
                eventSeq: eventSeq,
                resultSemantics: resultSemantics,
                items: &items,
                latestResultSeq: &latestResultSeq
            )
        }
    }

    private static func decodeCompleteStreamTail(
        _ buffer: String,
        eventSeq: Int64,
        resultSemantics: ResultSemantics,
        items: inout [RemoteTranscriptItem],
        latestResultSeq: inout Int64?
    ) {
        let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let payload = parse(line) else { return }
        appendPayload(
            payload,
            eventSeq: eventSeq,
            resultSemantics: resultSemantics,
            items: &items,
            latestResultSeq: &latestResultSeq
        )
    }

    private static func appendPayload(
        _ payload: [String: Any],
        eventSeq: Int64,
        resultSemantics: ResultSemantics,
        items: inout [RemoteTranscriptItem],
        latestResultSeq: inout Int64?
    ) {
        switch payload["type"] as? String {
        case "user":
            append(&items, id: eventSeq, role: .user, text: messageText(payload))
        case "assistant":
            append(&items, id: eventSeq, role: .assistant, text: messageText(payload))
        case "tool_result":
            let isError = payload["is_error"] as? Bool ?? false
            append(
                &items, id: eventSeq, role: .tool(isError: isError),
                text: contentText(payload["content"])
            )
        case "output":
            appendTerminal(
                &items,
                id: eventSeq,
                text: payload["text"] as? String ?? ""
            )
        case "system", "result":
            if payload["type"] as? String == "result" {
                latestResultSeq = max(latestResultSeq ?? 0, eventSeq)
            }
            appendStatus(
                &items,
                id: eventSeq,
                payload: payload,
                resultSemantics: resultSemantics
            )
        default:
            return
        }
    }

    private static func appendTerminal(
        _ items: inout [RemoteTranscriptItem],
        id: Int64,
        text rawText: String
    ) {
        let text = cleanTerminalText(rawText)
        guard !text.isEmpty else { return }
        if let last = items.last, last.role == .terminal {
            items[items.count - 1] = RemoteTranscriptItem(
                id: last.id, role: .terminal,
                text: mergeTerminal(last.text, text)
            )
        } else {
            items.append(RemoteTranscriptItem(id: id, role: .terminal, text: text))
        }
    }

    private static func appendStatus(
        _ items: inout [RemoteTranscriptItem],
        id: Int64,
        payload: [String: Any],
        resultSemantics: ResultSemantics
    ) {
        switch payload["type"] as? String {
        case "system":
            switch payload["subtype"] as? String {
            case "init":
                let cwd = payload["cwd"] as? String ?? ""
                append(
                    &items, id: id, role: .status,
                    text: cwd.isEmpty ? "Session started" : "Session started in \(cwd)"
                )
            case "stderr":
                append(
                    &items, id: id, role: .status,
                    text: cleanTerminalText(payload["text"] as? String ?? "")
                )
            default:
                return
            }
        case "result":
            let isError = payload["is_error"] as? Bool ?? false
            let successText = resultSemantics == .turn ? "Turn complete" : "Session finished"
            let errorText = resultSemantics == .turn
                ? "Turn finished with an error"
                : "Session finished with an error"
            append(
                &items, id: id, role: .status,
                text: isError ? errorText : successText
            )
        default:
            return
        }
    }

}

extension RemoteTranscript {
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

    // MARK: - Helpers

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func messageText(_ payload: [String: Any]) -> String {
        guard let message = payload["message"] as? [String: Any] else { return "" }
        return contentText(message["content"])
    }

    /// Join the text blocks of a stream-json content array.
    private static func contentText(_ content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks
            .compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            .joined(separator: "\n")
    }

    private static func append(
        _ items: inout [RemoteTranscriptItem], id: Int64,
        role: RemoteTranscriptItem.Role, text: String
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(RemoteTranscriptItem(id: id, role: role, text: trimmed))
    }

    private static func mergeTerminal(_ existing: String, _ incoming: String) -> String {
        let merged = existing + incoming
        // Keep terminal blocks bounded; the transcript is a view, not a log.
        return String(merged.suffix(20_000))
    }
}
