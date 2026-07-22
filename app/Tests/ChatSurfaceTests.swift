import XCTest
@testable import CovenPocket

final class ChatSurfaceTests: XCTestCase {
    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testStartChatCreatesIdleSession() throws {
        let engine = PocketEngine()
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let session = try engine.startChat(
            provider: .anthropic,
            apiKey: "test-key",
            model: "claude-test",
            effort: "medium",
            workspaceDir: workspace.path,
            permissionMode: .default
        )
        XCTAssertFalse(session.isBusy())
    }

    func testStartChatTranscriptStartsEmpty() async throws {
        let engine = PocketEngine()
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let session = try engine.startChat(
            provider: .anthropic,
            apiKey: "test-key",
            model: "claude-test",
            effort: nil,
            workspaceDir: workspace.path,
            permissionMode: .default
        )
        let transcript = await session.transcript()
        XCTAssertTrue(transcript.isEmpty)
    }

    func testStartChatRejectsRelativeWorkspace() {
        let engine = PocketEngine()
        XCTAssertThrowsError(
            try engine.startChat(
                provider: .anthropic,
                apiKey: "test-key",
                model: "claude-test",
                effort: nil,
                workspaceDir: "relative/workspace",
                permissionMode: .default
            )
        )
    }

    @MainActor
    func testToolInputSummaryPrefersPathKeys() {
        let summary = ChatModel.summarizeToolInput(
            name: "Read",
            json: #"{"file_path": "/some/absolute/notes.md"}"#
        )
        XCTAssertEqual(summary, "/some/absolute/notes.md")
    }

    @MainActor
    func testToolInputSummaryShortensWorkspacePaths() {
        let path = ChatModel.workspaceURL.appendingPathComponent("src/main.rs").path
        let summary = ChatModel.summarizeToolInput(
            name: "Edit",
            json: #"{"file_path": "\#(path)"}"#
        )
        XCTAssertEqual(summary, "src/main.rs")
    }

    @MainActor
    func testToolInputSummaryHandlesBatchEdit() {
        let summary = ChatModel.summarizeToolInput(
            name: "BatchEdit",
            json: #"{"edits": [{"file_path": "/a.txt"}, {"file_path": "/b.txt"}, {"file_path": "/a.txt"}]}"#
        )
        XCTAssertEqual(summary, "/a.txt, /b.txt")
    }

    @MainActor
    func testToolInputSummaryHandlesMalformedJson() {
        XCTAssertEqual(ChatModel.summarizeToolInput(name: "Read", json: "not json"), "")
    }

    // MARK: - Permissions

    private final class FakeResponder: ApprovalResponding {
        var decisions: [ChatPermissionDecision] = []
        func respond(decision: ChatPermissionDecision) {
            decisions.append(decision)
        }
    }

    @MainActor
    private func makeApproval(id: UInt64, responder: ApprovalResponding) -> PendingApproval {
        PendingApproval(
            request: ChatPermissionRequest(
                requestId: id,
                toolName: "Edit",
                paths: "notes.md",
                preview: "old -> new"
            ),
            responder: responder
        )
    }

    func testPermissionModeStorageRoundTrip() {
        for mode in ChatPermissionMode.all {
            XCTAssertEqual(ChatPermissionMode(storageValue: mode.storageValue), mode)
        }
        XCTAssertEqual(ChatPermissionMode(storageValue: nil), .default)
        XCTAssertEqual(ChatPermissionMode(storageValue: "garbage"), .default)
    }

    @MainActor
    func testPermissionModePersistsToDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "chat-tests-\(UUID().uuidString)"))
        let model = ChatModel(defaults: defaults)
        XCTAssertEqual(model.permissionMode, .default)

        model.permissionMode = .plan
        XCTAssertEqual(
            defaults.string(forKey: ChatModel.permissionModeKey),
            ChatPermissionMode.plan.storageValue
        )
        XCTAssertEqual(ChatModel(defaults: defaults).permissionMode, .plan)
    }

    @MainActor
    func testApprovalQueueShowsOneSheetAtATime() {
        let model = ChatModel()
        let responder = FakeResponder()

        model.receiveApproval(makeApproval(id: 1, responder: responder))
        model.receiveApproval(makeApproval(id: 2, responder: responder))
        XCTAssertEqual(model.pendingApproval?.id, 1)

        model.respond(to: makeApproval(id: 1, responder: responder), decision: .allow)
        XCTAssertNil(model.pendingApproval)
        XCTAssertEqual(responder.decisions, [.allow])

        model.approvalDismissed()
        XCTAssertEqual(model.pendingApproval?.id, 2)
    }

    @MainActor
    func testRespondIgnoresStaleApproval() {
        let model = ChatModel()
        let onScreen = FakeResponder()
        let stale = FakeResponder()

        model.receiveApproval(makeApproval(id: 7, responder: onScreen))
        model.respond(to: makeApproval(id: 3, responder: stale), decision: .deny)

        XCTAssertEqual(stale.decisions, [.deny])
        XCTAssertEqual(model.pendingApproval?.id, 7, "answering a stale request must not dismiss the live sheet")
    }

    @MainActor
    func testResetClearsPendingApprovals() {
        let model = ChatModel()
        model.receiveApproval(makeApproval(id: 1, responder: FakeResponder()))
        model.receiveApproval(makeApproval(id: 2, responder: FakeResponder()))

        model.reset()
        XCTAssertNil(model.pendingApproval)
        model.approvalDismissed()
        XCTAssertNil(model.pendingApproval, "queued approvals must not survive a reset")
    }
}
