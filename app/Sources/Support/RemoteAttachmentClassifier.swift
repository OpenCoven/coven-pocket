import Foundation

enum RemoteAttachmentClassifier {
    private struct Evidence {
        var bufferedOutput = ""
        var hasPTYOutput = false
        var hasStreamFrame = false
    }

    private struct ModeEvidence {
        var hasPTY = false
        var hasStream = false
    }

    static func classify(
        _ events: [RemoteEvent]
    ) -> RemoteTranscript.AttachmentMode {
        let evidence = collectEvidence(events)
        let buffered = classifyBufferedOutput(evidence.bufferedOutput)
        let hasStream = evidence.hasStreamFrame || buffered.hasStream
        let hasPTY = evidence.hasPTYOutput || buffered.hasPTY
        if hasStream && hasPTY {
            return .unknown
        }
        if hasStream { return .stream }
        if hasPTY { return .pty }
        return .unknown
    }

    private static func collectEvidence(_ events: [RemoteEvent]) -> Evidence {
        var evidence = Evidence()
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            if isDirectStreamEvent(event) {
                evidence.hasStreamFrame = true
            }
            guard event.kind == "output" else { continue }
            guard let outer = parse(event.payloadJson) else { continue }
            if outer["text"] is String {
                evidence.hasPTYOutput = true
            }
            guard let data = outer["data"] as? String else { continue }
            let standalone = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if let payload = parse(standalone),
               isStreamPayload(payload) {
                evidence.hasStreamFrame = true
            } else {
                evidence.bufferedOutput.append(data)
            }
        }
        return evidence
    }

    private static func isDirectStreamEvent(_ event: RemoteEvent) -> Bool {
        let directKinds = ["system", "user", "assistant", "tool_result"]
        guard directKinds.contains(event.kind),
              let payload = parse(event.payloadJson)
        else {
            return false
        }
        return payload["type"] as? String == event.kind
    }

    private static func classifyBufferedOutput(_ output: String) -> ModeEvidence {
        let lines = output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var evidence = ModeEvidence()
        for line in lines.dropLast() {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let payload = parse(text) else {
                evidence.hasPTY = true
                continue
            }
            if isStreamPayload(payload) {
                evidence.hasStream = true
            } else {
                evidence.hasPTY = true
            }
        }

        let remainder = String(lines.last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let payload = parse(remainder),
           isStreamPayload(payload) {
            evidence.hasStream = true
        } else if !remainder.isEmpty && !remainder.hasPrefix("{") {
            evidence.hasPTY = true
        }
        return evidence
    }

    private static func isStreamPayload(_ payload: [String: Any]) -> Bool {
        guard let type = payload["type"] as? String else { return false }
        return ["system", "user", "assistant", "tool_result", "result", "output"]
            .contains(type)
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
