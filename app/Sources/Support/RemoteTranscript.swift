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
    /// Build display items from the full accumulated event list.
    /// Consecutive `output` frames merge into one terminal block, since
    /// PTY chunk boundaries are arbitrary.
    static func items(from events: [RemoteEvent]) -> [RemoteTranscriptItem] {
        var items: [RemoteTranscriptItem] = []
        for event in events {
            guard let payload = parse(event.payloadJson) else { continue }
            switch payload["type"] as? String {
            case "user":
                append(&items, id: event.seq, role: .user, text: messageText(payload))
            case "assistant":
                append(&items, id: event.seq, role: .assistant, text: messageText(payload))
            case "tool_result":
                let isError = payload["is_error"] as? Bool ?? false
                append(
                    &items, id: event.seq, role: .tool(isError: isError),
                    text: contentText(payload["content"])
                )
            case "output":
                appendTerminal(&items, id: event.seq, payload: payload)
            case "system", "result":
                appendStatus(&items, id: event.seq, payload: payload)
            default:
                continue
            }
        }
        return items
    }

    private static func appendTerminal(
        _ items: inout [RemoteTranscriptItem], id: Int64, payload: [String: Any]
    ) {
        let text = cleanTerminalText(payload["text"] as? String ?? "")
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
        _ items: inout [RemoteTranscriptItem], id: Int64, payload: [String: Any]
    ) {
        switch payload["type"] as? String {
        case "system":
            guard payload["subtype"] as? String == "init" else { return }
            let cwd = payload["cwd"] as? String ?? ""
            append(
                &items, id: id, role: .status,
                text: cwd.isEmpty ? "Session started" : "Session started in \(cwd)"
            )
        case "result":
            let isError = payload["is_error"] as? Bool ?? false
            append(
                &items, id: id, role: .status,
                text: isError ? "Session finished with an error" : "Session finished"
            )
        default:
            return
        }
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
