import XCTest
@testable import CovenPocket

private func event(seq: Int64, kind: String, payload: String) -> RemoteEvent {
    RemoteEvent(seq: seq, kind: kind, payloadJson: payload, createdAt: "t")
}

/// Build a stream-json `user`/`assistant` frame with one text block.
private func messagePayload(_ role: String, _ text: String) -> String {
    #"{"type":"\#(role)","message":{"role":"\#(role)","content":"#
        + #"[{"type":"text","text":"\#(text)"}]}}"#
}

private final class InMemoryPairingStore: PairingStore {
    var stored: DaemonPairing?

    func load() -> DaemonPairing? { stored }
    func save(_ pairing: DaemonPairing) { stored = pairing }
    func clear() { stored = nil }
}

@MainActor
private func makeCompanion() -> CompanionModel {
    let defaults = UserDefaults(suiteName: "attach-tests-\(UUID().uuidString)")!
    return CompanionModel(defaults: defaults, store: InMemoryPairingStore())
}

final class RemoteAttachTests: XCTestCase {
    // MARK: - Transcript mapping

    func testTranscriptMapsStreamJsonKinds() {
        let events = [
            event(
                seq: 1, kind: "system",
                payload: #"{"type":"system","subtype":"init","cwd":"/work/app"}"#
            ),
            event(
                seq: 2, kind: "user",
                payload: messagePayload("user", "fix the bug")
            ),
            event(
                seq: 3, kind: "assistant",
                payload: messagePayload("assistant", "On it.")
            ),
            event(
                seq: 4, kind: "tool_result",
                payload: #"{"type":"tool_result","tool_use_id":"t1","content":"#
                    + #"[{"type":"text","text":"3 files changed"}],"is_error":false}"#
            ),
            event(
                seq: 5, kind: "result",
                payload: #"{"type":"result","subtype":"success","is_error":false}"#
            )
        ]
        let items = RemoteTranscript.items(from: events)
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0].role, .status)
        XCTAssertTrue(items[0].text.contains("/work/app"))
        XCTAssertEqual(items[1].role, .user)
        XCTAssertEqual(items[1].text, "fix the bug")
        XCTAssertEqual(items[2].role, .assistant)
        XCTAssertEqual(items[3].role, .tool(isError: false))
        XCTAssertEqual(items[3].text, "3 files changed")
        XCTAssertEqual(items[4].role, .status)
    }

    func testConsecutiveOutputFramesMergeIntoOneTerminalBlock() {
        let events = [
            event(seq: 1, kind: "output", payload: #"{"type":"output","text":"$ cargo te"}"#),
            event(seq: 2, kind: "output", payload: #"{"type":"output","text":"st\nrunning 5 tests\n"}"#),
            event(
                seq: 3, kind: "assistant",
                payload: messagePayload("assistant", "done")
            )
        ]
        let items = RemoteTranscript.items(from: events)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].role, .terminal)
        XCTAssertTrue(items[0].text.contains("$ cargo test"))
        XCTAssertTrue(items[0].text.contains("running 5 tests"))
    }

    func testUnknownKindsAndMalformedPayloadsAreSkipped() {
        let events = [
            event(seq: 1, kind: "mystery", payload: #"{"type":"mystery"}"#),
            event(seq: 2, kind: "assistant", payload: "not json at all")
        ]
        XCTAssertTrue(RemoteTranscript.items(from: events).isEmpty)
    }

    // MARK: - Terminal text cleaning

    func testCleanTerminalTextStripsAnsiAndAppliesCarriageReturns() {
        let raw = "\u{1B}[32mPASS\u{1B}[0m line\nprogress 10%\rprogress 100%\n"
        let cleaned = RemoteTranscript.cleanTerminalText(raw)
        XCTAssertEqual(cleaned, "PASS line\nprogress 100%\n")
    }

    // MARK: - Approval detection

    func testApprovalPromptDetectedInTerminalTail() {
        let items = [
            RemoteTranscriptItem(
                id: 1, role: .terminal,
                text: "About to run: rm -rf build\nAllow this command? [y/n]"
            )
        ]
        let prompt = RemoteTranscript.approvalPrompt(in: items)
        XCTAssertEqual(prompt, "Allow this command? [y/n]")
    }

    func testNoApprovalPromptOnPlainOutputOrNonTerminalTail() {
        XCTAssertNil(
            RemoteTranscript.approvalPrompt(in: [
                RemoteTranscriptItem(id: 1, role: .terminal, text: "compiling…\nall good")
            ])
        )
        XCTAssertNil(
            RemoteTranscript.approvalPrompt(in: [
                RemoteTranscriptItem(id: 1, role: .terminal, text: "Proceed? (y/N)"),
                RemoteTranscriptItem(id: 2, role: .assistant, text: "done")
            ]),
            "an answer after the prompt clears it"
        )
    }

    // MARK: - Attach model state

    @MainActor
    func testAttachModelDerivesApprovalAndCompletion() {
        let session = RemoteSession(
            id: "s-1", harness: "codex", title: "T", status: "running",
            projectRoot: "/w", createdAt: "c", updatedAt: "u"
        )
        let model = RemoteAttachModel(session: session, companion: makeCompanion())

        model.apply(events: [
            event(seq: 1, kind: "output", payload: #"{"type":"output","text":"Approve edit? [y/n]"}"#)
        ])
        XCTAssertNotNil(model.approvalPrompt)
        XCTAssertFalse(model.finished)

        model.apply(events: [
            event(seq: 1, kind: "output", payload: #"{"type":"output","text":"Approve edit? [y/n]"}"#),
            event(seq: 2, kind: "result", payload: #"{"type":"result","subtype":"success","is_error":false}"#)
        ])
        XCTAssertNil(model.approvalPrompt)
        XCTAssertTrue(model.finished)
    }

    @MainActor
    func testAttachRefusesTrafficWhenNotPaired() async {
        let session = RemoteSession(
            id: "s-1", harness: "codex", title: "T", status: "running",
            projectRoot: "/w", createdAt: "c", updatedAt: "u"
        )
        let model = RemoteAttachModel(session: session, companion: makeCompanion())

        await model.attach()
        XCTAssertNotNil(model.errorText)
        XCTAssertTrue(model.items.isEmpty)

        model.draft = "hello"
        await model.send()
        XCTAssertNotNil(model.errorText)
    }
}
