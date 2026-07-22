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
            permissionMode: .default,
            storageDir: nil
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
            permissionMode: .default,
            storageDir: nil
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
                permissionMode: .default,
                storageDir: nil
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

    // MARK: - Session browser

    @MainActor
    func testTranscriptItemsMapRoles() {
        let items = ChatModel.items(fromTranscript: [
            ChatMessage(role: "user", text: "hello"),
            ChatMessage(role: "assistant", text: "hi"),
            ChatMessage(role: "user", text: "again")
        ])
        XCTAssertEqual(items.map(\.kind), [.user, .assistant, .user])
        XCTAssertEqual(items.map(\.text), ["hello", "hi", "again"])
    }

    private func makeSummary(
        title: String = "t",
        updatedAt: String = "2026-01-02T03:04:05+00:00"
    ) -> ChatSessionSummary {
        ChatSessionSummary(
            sessionId: UUID().uuidString.lowercased(),
            title: title,
            model: "claude-test",
            createdAt: "2026-01-01T00:00:00+00:00",
            updatedAt: updatedAt,
            messageCount: 2
        )
    }

    func testSummaryParsesChronoTimestamps() {
        // chrono's to_rfc3339 emits nanosecond fractions.
        let nano = makeSummary(updatedAt: "2026-01-02T03:04:05.123456789+00:00")
        XCTAssertNotNil(nano.updatedDate)
        let plain = makeSummary(updatedAt: "2026-01-02T03:04:05+00:00")
        XCTAssertNotNil(plain.updatedDate)
        XCTAssertEqual(nano.updatedDate?.timeIntervalSince1970.rounded(),
                       plain.updatedDate?.timeIntervalSince1970.rounded())
        XCTAssertNil(makeSummary(updatedAt: "not a date").updatedDate)
    }

    func testSummaryDisplayTitleFallsBack() {
        XCTAssertEqual(makeSummary(title: "Fix the bug").displayTitle, "Fix the bug")
        XCTAssertEqual(makeSummary(title: "").displayTitle, "Untitled session")
        let summary = makeSummary()
        XCTAssertEqual(summary.id, summary.sessionId)
    }

    // MARK: - Git workspaces

    private func makeRepoSummary(
        name: String = "widget",
        dirty: UInt32 = 0,
        ahead: UInt32 = 0,
        behind: UInt32 = 0
    ) -> GitWorkspaceSummary {
        GitWorkspaceSummary(
            name: name,
            path: "/tmp/repos/\(name)",
            branch: "main",
            remoteUrl: nil,
            dirtyCount: dirty,
            ahead: ahead,
            behind: behind
        )
    }

    func testWorkspaceStatusLine() {
        XCTAssertEqual(makeRepoSummary().statusLine, "main")
        XCTAssertEqual(
            makeRepoSummary(dirty: 2, ahead: 1, behind: 3).statusLine,
            "main · 2 changed · ↑1 · ↓3"
        )
        XCTAssertEqual(makeRepoSummary().id, "widget")
    }

    @MainActor
    func testActiveRepoSelectionPersistsForChat() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "repo-tests-\(UUID().uuidString)"))
        let repos = RepoModel(defaults: defaults)
        let workspace = makeRepoSummary()

        repos.setActive(workspace)
        XCTAssertEqual(repos.activeRepoName, "widget")
        XCTAssertEqual(
            defaults.string(forKey: ChatModel.activeWorkspacePathKey),
            workspace.path
        )

        repos.setActive(nil)
        XCTAssertNil(repos.activeRepoName)
        XCTAssertNil(defaults.string(forKey: ChatModel.activeWorkspacePathKey))
    }

    @MainActor
    func testEffectiveWorkspaceFollowsActiveRepoPath() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "chat-ws-\(UUID().uuidString)"))
        let model = ChatModel(defaults: defaults)

        // No selection: scratch workspace.
        XCTAssertEqual(model.effectiveWorkspaceURL, ChatModel.workspaceURL)

        // A selection pointing at a real directory wins.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocket-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults.set(dir.path, forKey: ChatModel.activeWorkspacePathKey)
        XCTAssertEqual(model.effectiveWorkspaceURL.path, dir.path)

        // Stale selections fall back to the scratch workspace.
        try FileManager.default.removeItem(at: dir)
        XCTAssertEqual(model.effectiveWorkspaceURL, ChatModel.workspaceURL)

        // A path pointing at a plain file is not a workspace either.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocket-file-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        defaults.set(file.path, forKey: ChatModel.activeWorkspacePathKey)
        XCTAssertEqual(model.effectiveWorkspaceURL, ChatModel.workspaceURL)
    }
}
