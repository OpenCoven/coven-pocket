import XCTest
@testable import CovenPocket

private final class ConflictPairingStore: PairingStore {
    func load() -> DaemonPairing? { nil }
    func save(_ pairing: DaemonPairing) {}
    func clear() {}
}

@MainActor
final class RemoteAttachmentConflictTests: XCTestCase {
    func testConflictingPTYAndStreamEvidenceKeepsInputDisabled() throws {
        let model = makeModel()
        model.apply(events: [
            try outputEvent(seq: 1, data: "Approve? [y/n]\n"),
            try outputEvent(
                seq: 2,
                data: #"{"type":"result","is_error":false}"# + "\n"
            )
        ])

        XCTAssertFalse(model.acceptsInput)
        XCTAssertNil(model.approvalPrompt)
    }

    func testConflictingEvidenceWithinOneOutputKeepsInputDisabled() throws {
        let model = makeModel()
        model.apply(events: [
            try outputEvent(
                seq: 1,
                data: "plain PTY output\n"
                    + #"{"type":"result","is_error":false}"# + "\n"
            )
        ])

        XCTAssertFalse(model.acceptsInput)
        XCTAssertNil(model.approvalPrompt)
    }

    func testLaterConflictingEvidenceDisablesPreviouslyKnownMode() throws {
        let model = makeModel()
        let ptyEvent = try outputEvent(seq: 1, data: "Approve? [y/n]\n")

        model.apply(events: [ptyEvent])
        XCTAssertTrue(model.acceptsInput)
        model.apply(events: [
            ptyEvent,
            try outputEvent(
                seq: 2,
                data: #"{"type":"result","is_error":false}"# + "\n"
            )
        ])

        XCTAssertFalse(model.acceptsInput)
        XCTAssertNil(model.approvalPrompt)
    }

    func testDirectStreamFrameConflictsWithPTYInEitherOrder() throws {
        let pty = try outputEvent(seq: 1, data: "Approve? [y/n]\n")
        let assistant = RemoteEvent(
            seq: 2,
            kind: "assistant",
            payloadJson: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hi"}]}}"#,
            createdAt: "t"
        )

        for events in [[pty, assistant], [assistant, pty]] {
            let model = makeModel()
            model.apply(events: events)
            XCTAssertFalse(model.acceptsInput)
            XCTAssertNil(model.approvalPrompt)
        }
    }

    private func makeModel() -> RemoteAttachModel {
        let defaults = UserDefaults(
            suiteName: "attach-conflict-tests-\(UUID().uuidString)"
        )!
        let companion = CompanionModel(
            defaults: defaults,
            store: ConflictPairingStore()
        )
        let session = RemoteSession(
            id: "s-1",
            harness: "claude",
            title: "T",
            status: "running",
            projectRoot: "/w",
            createdAt: "c",
            updatedAt: "u",
            familiarId: nil
        )
        return RemoteAttachModel(session: session, companion: companion)
    }

    private func outputEvent(seq: Int64, data: String) throws -> RemoteEvent {
        let payload = try JSONSerialization.data(withJSONObject: ["data": data])
        return RemoteEvent(
            seq: seq,
            kind: "output",
            payloadJson: try XCTUnwrap(String(data: payload, encoding: .utf8)),
            createdAt: "t"
        )
    }
}
