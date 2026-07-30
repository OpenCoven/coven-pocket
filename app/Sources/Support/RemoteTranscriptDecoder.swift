import Foundation

struct RemoteTranscriptDecoder {
    let resultSemantics: RemoteTranscript.ResultSemantics
    private(set) var items: [RemoteTranscriptItem] = []
    private(set) var latestResultSeq: Int64?
    private(set) var sessionEnded = false
    private var streamBuffer = ""

    init(resultSemantics: RemoteTranscript.ResultSemantics) {
        self.resultSemantics = resultSemantics
    }

    mutating func decode(_ event: RemoteEvent) {
        guard let payload = Self.parse(event.payloadJson) else { return }
        if event.kind == "input" {
            append(
                id: event.seq,
                role: .user,
                text: payload["data"] as? String ?? ""
            )
        } else if event.kind == "exit" || event.kind == "kill" {
            sessionEnded = true
            appendSessionEnd(event, payload: payload)
        } else if event.kind == "output",
                  let data = payload["data"] as? String {
            decodeOutput(data, eventSeq: event.seq)
        } else {
            appendPayload(payload, eventSeq: event.seq)
        }
    }

    private mutating func appendSessionEnd(
        _ event: RemoteEvent,
        payload: [String: Any]
    ) {
        let status = payload["status"] as? String
        append(
            id: event.seq,
            role: .status,
            text: event.kind == "kill"
                ? "Session stopped"
                : "Session \(status ?? "ended")"
        )
    }

    private mutating func decodeOutput(_ data: String, eventSeq: Int64) {
        guard resultSemantics == .turn else {
            appendTerminal(id: eventSeq, text: data)
            return
        }
        if let standalone = Self.parse(
            data.trimmingCharacters(in: .whitespacesAndNewlines)
        ),
            standalone["type"] as? String == "system",
            standalone["subtype"] as? String == "stderr" {
            appendPayload(standalone, eventSeq: eventSeq)
            return
        }
        streamBuffer.append(data)
        decodeStreamLines(eventSeq: eventSeq)
        decodeCompleteRemainder(eventSeq: eventSeq)
    }

    private mutating func decodeStreamLines(eventSeq: Int64) {
        while let newline = streamBuffer.firstIndex(of: "\n") {
            let line = String(streamBuffer[..<newline])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            streamBuffer.removeSubrange(...newline)
            guard !line.isEmpty, let payload = Self.parse(line) else { continue }
            appendPayload(payload, eventSeq: eventSeq)
        }
    }

    private mutating func decodeCompleteRemainder(eventSeq: Int64) {
        let remainder = streamBuffer.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !remainder.isEmpty,
              let payload = Self.parse(remainder)
        else {
            return
        }
        streamBuffer = ""
        appendPayload(payload, eventSeq: eventSeq)
    }
}

private extension RemoteTranscriptDecoder {
    mutating func appendPayload(_ payload: [String: Any], eventSeq: Int64) {
        switch payload["type"] as? String {
        case "user":
            append(id: eventSeq, role: .user, text: Self.messageText(payload))
        case "assistant":
            append(id: eventSeq, role: .assistant, text: Self.messageText(payload))
        case "tool_result":
            let isError = payload["is_error"] as? Bool ?? false
            append(
                id: eventSeq,
                role: .tool(isError: isError),
                text: Self.contentText(payload["content"])
            )
        case "output":
            appendTerminal(
                id: eventSeq,
                text: payload["text"] as? String ?? ""
            )
        case "system", "result":
            if payload["type"] as? String == "result" {
                latestResultSeq = max(latestResultSeq ?? 0, eventSeq)
            }
            appendStatus(id: eventSeq, payload: payload)
        default:
            return
        }
    }

    mutating func appendTerminal(id: Int64, text rawText: String) {
        let text = RemoteTranscript.cleanTerminalText(rawText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if let last = items.last, last.role == .terminal {
            items[items.count - 1] = RemoteTranscriptItem(
                identity: last.id,
                role: .terminal,
                text: Self.mergeTerminal(last.text, text)
            )
        } else {
            items.append(
                RemoteTranscriptItem(
                    identity: RemoteTranscriptItem.Identity(
                        eventSequence: id,
                        ordinal: items.count
                    ),
                    role: .terminal,
                    text: text
                )
            )
        }
    }

    mutating func appendStatus(id: Int64, payload: [String: Any]) {
        switch payload["type"] as? String {
        case "system":
            appendSystemStatus(id: id, payload: payload)
        case "result":
            let isError = payload["is_error"] as? Bool ?? false
            let successText = resultSemantics == .turn ? "Turn complete" : "Session finished"
            let errorText = resultSemantics == .turn
                ? "Turn finished with an error"
                : "Session finished with an error"
            append(
                id: id,
                role: .status,
                text: isError ? errorText : successText
            )
        default:
            return
        }
    }

    mutating func appendSystemStatus(id: Int64, payload: [String: Any]) {
        switch payload["subtype"] as? String {
        case "init":
            let cwd = payload["cwd"] as? String ?? ""
            append(
                id: id,
                role: .status,
                text: cwd.isEmpty ? "Session started" : "Session started in \(cwd)"
            )
        case "stderr":
            append(
                id: id,
                role: .status,
                text: RemoteTranscript.cleanTerminalText(
                    payload["text"] as? String ?? ""
                )
            )
        default:
            return
        }
    }

    mutating func append(
        id: Int64,
        role: RemoteTranscriptItem.Role,
        text: String
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(
            RemoteTranscriptItem(
                identity: RemoteTranscriptItem.Identity(
                    eventSequence: id,
                    ordinal: items.count
                ),
                role: role,
                text: trimmed
            )
        )
    }

    static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func messageText(_ payload: [String: Any]) -> String {
        guard let message = payload["message"] as? [String: Any] else { return "" }
        return contentText(message["content"])
    }

    static func contentText(_ content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks
            .compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            .joined(separator: "\n")
    }

    static func mergeTerminal(_ existing: String, _ incoming: String) -> String {
        String((existing + incoming).suffix(20_000))
    }
}
