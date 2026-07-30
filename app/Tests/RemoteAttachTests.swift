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

    func testStreamResultMeansTurnCompleteWithoutChangingOneShotCopy() {
        let events = [
            event(
                seq: 1,
                kind: "result",
                payload: #"{"type":"result","subtype":"success","is_error":false}"#
            )
        ]

        XCTAssertEqual(RemoteTranscript.items(from: events)[0].text, "Session finished")
        XCTAssertEqual(
            RemoteTranscript.items(from: events, resultSemantics: .turn)[0].text,
            "Turn complete"
        )
    }

    func testDaemonInputEventsRenderAsUserTurns() {
        let events = [
            event(seq: 10, kind: "input", payload: #"{"data":"follow up"}"#)
        ]

        let items = RemoteTranscript.items(from: events, resultSemantics: .turn)

        XCTAssertEqual(items.map(\.role), [.user])
        XCTAssertEqual(items.map(\.text), ["follow up"])
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

    func testConsecutiveTerminalFramesPreserveNewlineBoundaries() {
        let events = [
            event(seq: 1, kind: "output", payload: #"{"type":"output","text":"line 1\n"}"#),
            event(seq: 2, kind: "output", payload: #"{"type":"output","text":"line 2\n"}"#)
        ]

        let items = RemoteTranscript.items(from: events)

        XCTAssertEqual(items.map(\.text), ["line 1\nline 2\n"])
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

}

@MainActor
final class RemoteAttachModelTests: XCTestCase {
    func testAttachModelDerivesApprovalAndCompletion() {
        let session = RemoteSession(
            id: "s-1", harness: "codex", title: "T", status: "running",
            projectRoot: "/w", createdAt: "c", updatedAt: "u"
        )
        let model = RemoteAttachModel(session: session, companion: makeCompanion())

        model.apply(events: [
            event(
                seq: 1,
                kind: "output",
                payload: #"{"data":"Approve edit? [y/n]"}"#
            )
        ])
        XCTAssertNotNil(model.approvalPrompt)
        XCTAssertTrue(model.acceptsInput)
        XCTAssertFalse(model.finished)

        model.apply(events: [
            event(
                seq: 1,
                kind: "output",
                payload: #"{"data":"Approve edit? [y/n]"}"#
            ),
            event(seq: 2, kind: "result", payload: #"{"type":"result","subtype":"success","is_error":false}"#)
        ])
        XCTAssertNil(model.approvalPrompt)
        XCTAssertTrue(model.finished)
    }

    @MainActor
    func testAttachModelDecodesStreamTurnsAndFinishesOnlyOnExit() throws {
        let session = RemoteSession(
            id: "s-1", harness: "claude", title: "T", status: "running",
            projectRoot: "/w", createdAt: "c", updatedAt: "u"
        )
        let model = RemoteAttachModel(session: session, companion: makeCompanion())
        let firstChunk = try JSONSerialization.data(
            withJSONObject: [
                "data": #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}"#
                    + "\n"
                    + #"{"type":"result","is_error":false}"# + "\n"
            ]
        )
        let firstPayload = try XCTUnwrap(String(data: firstChunk, encoding: .utf8))

        model.apply(events: [
            event(seq: 1, kind: "output", payload: firstPayload)
        ])

        XCTAssertEqual(model.items.map(\.text), ["Done", "Turn complete"])
        XCTAssertNil(model.approvalPrompt)
        XCTAssertFalse(model.finished)

        model.apply(events: [
            event(seq: 1, kind: "output", payload: firstPayload),
            event(seq: 2, kind: "exit", payload: #"{"status":"completed"}"#)
        ])
        XCTAssertTrue(model.finished)
    }

    func testMultipleStreamFramesInOneEventHaveUniqueIdentities() throws {
        let payloadData = try JSONSerialization.data(
            withJSONObject: [
                "data": #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}"#
                    + "\n"
                    + #"{"type":"result","is_error":false}"# + "\n"
            ]
        )
        let payload = try XCTUnwrap(String(data: payloadData, encoding: .utf8))

        let items = RemoteTranscript.attachmentSnapshot(
            from: [event(seq: 1, kind: "output", payload: payload)]
        ).items

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }

    @MainActor
    func testAttachModelDoesNotOfferTextApprovalForStreamOutput() throws {
        let session = RemoteSession(
            id: "s-1", harness: "claude", title: "T", status: "running",
            projectRoot: "/w", createdAt: "c", updatedAt: "u"
        )
        let model = RemoteAttachModel(session: session, companion: makeCompanion())
        let data = try JSONSerialization.data(
            withJSONObject: [
                "data": #"{"type":"output","text":"Allow this command? [y/n]"}"# + "\n"
            ]
        )

        model.apply(events: [
            event(
                seq: 1,
                kind: "output",
                payload: try XCTUnwrap(String(data: data, encoding: .utf8))
            )
        ])

        XCTAssertNil(model.approvalPrompt)
    }

    @MainActor
    func testAttachModelKeepsInputDisabledUntilSessionModeIsKnown() {
        let session = RemoteSession(
            id: "s-1", harness: "claude", title: "T", status: "running",
            projectRoot: "/w", createdAt: "c", updatedAt: "u"
        )
        let model = RemoteAttachModel(session: session, companion: makeCompanion())

        model.apply(events: [])

        XCTAssertFalse(model.acceptsInput)
        XCTAssertNil(
            RemoteAttachModel.inputData("follow up", mode: .unknown)
        )
    }

    func testUnknownResultIsTurnCompleteButDoesNotFinishAttachment() {
        let session = RemoteSession(
            id: "s-1", harness: "claude", title: "T", status: "running",
            projectRoot: "/w", createdAt: "c", updatedAt: "u"
        )
        let model = RemoteAttachModel(session: session, companion: makeCompanion())

        model.apply(events: [
            event(
                seq: 1,
                kind: "result",
                payload: #"{"type":"result","is_error":false}"#
            )
        ])

        XCTAssertEqual(model.items.map(\.text), ["Turn complete"])
        XCTAssertFalse(model.finished)
        XCTAssertFalse(model.acceptsInput)
    }

    @MainActor
    func testPartialStreamPrefixDoesNotEnableInput() throws {
        let session = RemoteSession(
            id: "s-1", harness: "claude", title: "T", status: "running",
            projectRoot: "/w", createdAt: "c", updatedAt: "u"
        )
        let model = RemoteAttachModel(session: session, companion: makeCompanion())

        model.apply(events: [
            try streamOutputEvent(seq: 1, data: #"{"type":"ass"#)
        ])

        XCTAssertFalse(model.acceptsInput)
        XCTAssertNil(model.approvalPrompt)
    }

    @MainActor
    func testInterleavedStderrClassifiesAttachAsStream() throws {
        let session = RemoteSession(
            id: "s-1", harness: "claude", title: "T", status: "running",
            projectRoot: "/w", createdAt: "c", updatedAt: "u"
        )
        let model = RemoteAttachModel(session: session, companion: makeCompanion())
        let events = [
            try streamOutputEvent(seq: 1, data: #"{"type":"ass"#),
            try streamOutputEvent(
                seq: 2,
                data: #"{"type":"system","subtype":"stderr","text":"warning"}"# + "\n"
            ),
            try streamOutputEvent(
                seq: 3,
                data: #"istant","message":{"content":[{"type":"text","text":"Done"}]}}"# + "\n"
            )
        ]

        model.apply(events: events)

        XCTAssertTrue(model.acceptsInput)
        XCTAssertNil(model.approvalPrompt)
        XCTAssertEqual(model.items.map(\.text), ["warning", "Done"])
        XCTAssertEqual(
            RemoteAttachModel.inputData("follow up", mode: .stream),
            "follow up"
        )
    }

    @MainActor
    func testAttachInputFramingDependsOnDetectedSessionMode() {
        XCTAssertEqual(
            RemoteAttachModel.inputData("follow up", mode: .stream),
            "follow up"
        )
        XCTAssertEqual(
            RemoteAttachModel.inputData("follow up", mode: .pty),
            "follow up\n"
        )
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

    private func streamOutputEvent(seq: Int64, data: String) throws -> RemoteEvent {
        let payload = try JSONSerialization.data(withJSONObject: ["data": data])
        return event(
            seq: seq,
            kind: "output",
            payload: try XCTUnwrap(String(data: payload, encoding: .utf8))
        )
    }
}
