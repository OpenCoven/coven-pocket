import XCTest
@testable import CovenPocket

// Chat surface coverage is kept together to share the deterministic session seam.
// swiftlint:disable file_length

// swiftlint:disable:next type_body_length
final class ChatSurfaceTests: XCTestCase {
    private final class StubChatSession: ChatSession, @unchecked Sendable {
        private let transcriptMessages: [ChatMessage]

        init(transcript: [ChatMessage] = []) {
            transcriptMessages = transcript
            super.init(noHandle: ChatSession.NoHandle())
        }

        required init(unsafeFromHandle handle: UInt64) {
            transcriptMessages = []
            super.init(unsafeFromHandle: handle)
        }

        override func send(prompt: String, delegate: ChatDelegate) async throws {}

        override func transcript() async -> [ChatMessage] {
            transcriptMessages
        }

        override func stop() {}
    }

    private final class SuspendedChatSession: ChatSession, @unchecked Sendable {
        let sendRequested = XCTestExpectation(description: "chat send requested")

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var delegate: ChatDelegate?

        init() {
            super.init(noHandle: ChatSession.NoHandle())
        }

        required init(unsafeFromHandle handle: UInt64) {
            super.init(unsafeFromHandle: handle)
        }

        override func send(prompt: String, delegate: ChatDelegate) async throws {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                self.delegate = delegate
                lock.unlock()
                sendRequested.fulfill()
            }
        }

        override func stop() {}

        func publishStaleCallbackAndFinish() {
            lock.lock()
            let continuation = continuation
            let delegate = delegate
            self.continuation = nil
            self.delegate = nil
            lock.unlock()

            delegate?.onText(text: "stale callback")
            delegate?.onDone(stopReason: "cancelled")
            continuation?.resume()
        }
    }

    @MainActor
    private final class SessionBoundary {
        let startRequested = XCTestExpectation(description: "session start requested")
        let resumeRequested = XCTestExpectation(description: "session resume requested")

        var suspendNextStart = false
        var suspendNextResume = false
        var startCallCount = 0
        var resumeCallCount = 0
        var startSessions: [ChatSession] = []
        var resumeSessions: [ChatSession] = []

        private var startContinuation: CheckedContinuation<ChatSession, Error>?
        private var resumeContinuation: CheckedContinuation<ChatSession, Error>?

        func perform(
            _ kind: ChatModel.SessionOperationKind,
            operation: @MainActor () async throws -> ChatSession
        ) async throws -> ChatSession {
            switch kind {
            case .start:
                startCallCount += 1
                if suspendNextStart {
                    suspendNextStart = false
                    startRequested.fulfill()
                    return try await withCheckedThrowingContinuation { continuation in
                        startContinuation = continuation
                    }
                }
                if startSessions.isEmpty {
                    return try await operation()
                }
                return startSessions.removeFirst()
            case .resume:
                resumeCallCount += 1
                if suspendNextResume {
                    suspendNextResume = false
                    resumeRequested.fulfill()
                    return try await withCheckedThrowingContinuation { continuation in
                        resumeContinuation = continuation
                    }
                }
                if resumeSessions.isEmpty {
                    return try await operation()
                }
                return resumeSessions.removeFirst()
            }
        }

        func finishStart(with session: ChatSession) {
            let continuation = startContinuation
            startContinuation = nil
            continuation?.resume(returning: session)
        }

        func finishResume(with session: ChatSession) {
            let continuation = resumeContinuation
            resumeContinuation = nil
            continuation?.resume(returning: session)
        }
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testChatSettingsDefaultToCompanionWithoutAnAPIKey() {
        let settings = ChatSettings()
        XCTAssertEqual(settings.backend, .companionClaude)
        XCTAssertEqual(settings.model, "")
        XCTAssertEqual(settings.daemonProjectRoot, "")
    }

    func testBackendChoicesGateCompanionOnVerifiedAvailability() {
        XCTAssertEqual(
            ChatBackend.available(companionAvailable: false, codexAvailable: true),
            [.codex]
        )
        XCTAssertEqual(
            ChatBackend.available(companionAvailable: true, codexAvailable: true),
            [.companionClaude, .codex]
        )
        XCTAssertEqual(
            ChatBackend.available(companionAvailable: true, codexAvailable: false),
            [.companionClaude]
        )
        XCTAssertTrue(
            ChatBackend.available(companionAvailable: false, codexAvailable: false).isEmpty
        )
    }

    func testCompanionChatHasNoPTYApprovalControls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Sources/Support/CompanionChatModel.swift",
            "Sources/Views/ChatView.swift"
        ]
        let source = try files
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertFalse(source.contains("companionApprovalBar"))
        XCTAssertFalse(source.contains("func approve()"))
        XCTAssertFalse(source.contains("func deny()"))
        XCTAssertFalse(source.contains("sendControl"))
    }

    func testChatSurfaceHasNoAnthropicAPIKeyUIOrKeychainRead() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Sources/Support/ChatTypes.swift",
            "Sources/Views/ChatView.swift",
            "Sources/Views/ChatSettingsView.swift"
        ]
        let source = try files
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertFalse(source.contains("anthropic-api-key"))
        XCTAssertFalse(source.contains("Anthropic API key"))
        XCTAssertFalse(source.contains("settings.apiKey"))
        XCTAssertTrue(source.contains("Claude via Companion"))
    }

    func testStartChatCreatesIdleSession() async throws {
        let engine = PocketEngine()
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let session = try await engine.startChat(
            provider: .anthropic,
            apiKey: "test-key",
            model: "claude-test",
            effort: "medium",
            workspaceDir: workspace.path,
            permissionMode: .default,
            storageDir: nil, familiar: nil,
            injectContext: false
        )
        XCTAssertFalse(session.isBusy())
    }

    func testStartChatTranscriptStartsEmpty() async throws {
        let engine = PocketEngine()
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let session = try await engine.startChat(
            provider: .anthropic,
            apiKey: "test-key",
            model: "claude-test",
            effort: nil,
            workspaceDir: workspace.path,
            permissionMode: .default,
            storageDir: nil, familiar: nil,
            injectContext: false
        )
        let transcript = await session.transcript()
        XCTAssertTrue(transcript.isEmpty)
    }

    func testStartChatRejectsRelativeWorkspace() async {
        let engine = PocketEngine()
        do {
            _ = try await engine.startChat(
                provider: .anthropic,
                apiKey: "test-key",
                model: "claude-test",
                effort: nil,
                workspaceDir: "relative/workspace",
                permissionMode: .default,
                storageDir: nil, familiar: nil,
                injectContext: false
            )
        } catch {
            return
        }
        XCTFail("Expected a relative workspace to be rejected")
    }

    @MainActor
    func testSecondSendIsRejectedWhileSessionCreationIsSuspended() async {
        let boundary = SessionBoundary()
        boundary.suspendNextStart = true
        boundary.startSessions = [StubChatSession()]
        let firstSession = StubChatSession()
        let model = ChatModel(
            performSessionOperation: boundary.perform
        )
        let settings = ChatSettings(backend: .codex, model: "test", daemonProjectRoot: "")

        let firstSend = Task {
            await model.send(prompt: "first", settings: settings)
        }
        await fulfillment(of: [boundary.startRequested], timeout: 1)

        XCTAssertTrue(model.isBusy)
        await model.send(prompt: "second", settings: settings)
        XCTAssertEqual(boundary.startCallCount, 1)

        boundary.finishStart(with: firstSession)
        await firstSend.value

        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.items.map(\.text), ["first"])
    }

    @MainActor
    func testResetInvalidatesSuspendedSessionCreation() async {
        let boundary = SessionBoundary()
        boundary.suspendNextStart = true
        boundary.startSessions = [StubChatSession()]
        let model = ChatModel(
            performSessionOperation: boundary.perform
        )
        let settings = ChatSettings(backend: .codex, model: "test", daemonProjectRoot: "")

        let staleSend = Task {
            await model.send(prompt: "stale", settings: settings)
        }
        await fulfillment(of: [boundary.startRequested], timeout: 1)

        model.reset()
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.items.isEmpty)

        boundary.finishStart(with: StubChatSession())
        await staleSend.value
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.items.isEmpty)

        await model.send(prompt: "fresh", settings: settings)
        XCTAssertEqual(boundary.startCallCount, 2)
        XCTAssertEqual(model.items.map(\.text), ["fresh"])
    }

    @MainActor
    func testStopInvalidatesSuspendedSessionCreation() async {
        let boundary = SessionBoundary()
        boundary.suspendNextStart = true
        boundary.startSessions = [StubChatSession()]
        let model = ChatModel(
            performSessionOperation: boundary.perform
        )
        let settings = ChatSettings(backend: .codex, model: "test", daemonProjectRoot: "")

        let staleSend = Task {
            await model.send(prompt: "stale", settings: settings)
        }
        await fulfillment(of: [boundary.startRequested], timeout: 1)

        model.stop()
        XCTAssertFalse(model.isBusy)

        boundary.finishStart(with: StubChatSession())
        await staleSend.value
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.items.isEmpty)

        await model.send(prompt: "fresh", settings: settings)
        XCTAssertEqual(boundary.startCallCount, 2)
        XCTAssertEqual(model.items.map(\.text), ["fresh"])
    }

    @MainActor
    func testResetDropsCallbacksFromInvalidatedRunningSend() async {
        let boundary = SessionBoundary()
        let staleSession = SuspendedChatSession()
        boundary.startSessions = [staleSession, StubChatSession()]
        let model = ChatModel(
            performSessionOperation: boundary.perform
        )
        let settings = ChatSettings(backend: .codex, model: "test", daemonProjectRoot: "")

        let staleSend = Task {
            await model.send(prompt: "stale", settings: settings)
        }
        await fulfillment(of: [staleSession.sendRequested], timeout: 1)

        model.reset()
        await model.send(prompt: "fresh", settings: settings)
        staleSession.publishStaleCallbackAndFinish()
        await staleSend.value
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.items.map(\.text), ["fresh"])
    }

    @MainActor
    func testResumeCannotOverlapSendOrPublishAfterReset() async {
        let boundary = SessionBoundary()
        boundary.suspendNextResume = true
        boundary.startSessions = [StubChatSession(), StubChatSession()]
        let resumedSession = StubChatSession(transcript: [
            ChatMessage(role: "assistant", text: "stale resume")
        ])
        let model = ChatModel(
            performSessionOperation: boundary.perform
        )
        let summary = makeSummary()
        let resumeSettings = ChatSettings(
            backend: .codex,
            model: "resume",
            daemonProjectRoot: ""
        )
        let sendSettings = ChatSettings(
            backend: .codex,
            model: "send",
            daemonProjectRoot: ""
        )

        let resume = Task {
            await model.resume(summary, settings: resumeSettings)
        }
        await fulfillment(of: [boundary.resumeRequested], timeout: 1)

        XCTAssertTrue(model.isBusy)
        await model.send(prompt: "blocked", settings: sendSettings)
        XCTAssertEqual(boundary.startCallCount, 0)

        model.reset()
        boundary.suspendNextStart = true
        let freshSend = Task {
            await model.send(prompt: "fresh", settings: sendSettings)
        }
        await fulfillment(of: [boundary.startRequested], timeout: 1)

        boundary.finishResume(with: resumedSession)
        await resume.value
        XCTAssertTrue(model.isBusy, "a stale resume must not finish the newer send")
        XCTAssertTrue(model.items.isEmpty, "a stale resume must not restore its transcript")

        boundary.finishStart(with: StubChatSession())
        await freshSend.value
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(boundary.resumeCallCount, 1)
        XCTAssertEqual(boundary.startCallCount, 1)
        XCTAssertEqual(model.items.map(\.text), ["fresh"])
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
            messageCount: 2, familiar: nil
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
}
