import XCTest
@testable import CovenPocket

// Chat surface coverage is kept together to share the deterministic session seam.
// swiftlint:disable file_length

@MainActor
private final class NoopFamiliarRosterClient: FamiliarRosterClient {
    func gate() async -> CompanionModel.SessionGate {
        .notPaired
    }

    func familiars(pairing: DaemonPairing) async throws -> [RemoteFamiliar] {
        []
    }
}

// swiftlint:disable:next type_body_length
final class ChatSurfaceTests: XCTestCase {
    private struct SpotlightResumePreparation {
        let suiteName: String
        let defaults: UserDefaults
        let store: FamiliarSelectionStore
        let familiarModel: FamiliarSelectionModel
        let settings: ChatSettings
        let codexProfile: FamiliarProfileKey
        let forge: FamiliarIdentity
    }

    private final class StubChatSession: ChatSession, @unchecked Sendable {
        private let transcriptMessages: [ChatMessage]
        private let sessionIdentifier: String

        init(
            transcript: [ChatMessage] = [],
            sessionIdentifier: String = UUID().uuidString
        ) {
            transcriptMessages = transcript
            self.sessionIdentifier = sessionIdentifier
            super.init(noHandle: ChatSession.NoHandle())
        }

        required init(unsafeFromHandle handle: UInt64) {
            transcriptMessages = []
            sessionIdentifier = UUID().uuidString
            super.init(unsafeFromHandle: handle)
        }

        override func send(prompt: String, delegate: ChatDelegate) async throws {}

        override func transcript() async -> [ChatMessage] {
            transcriptMessages
        }

        override func sessionId() -> String {
            sessionIdentifier
        }

        override func stop() {}
    }

    private final class SuspendedChatSession: ChatSession, @unchecked Sendable {
        let sendRequested = XCTestExpectation(description: "chat send requested")

        private let sessionIdentifier = UUID().uuidString
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

        override func sessionId() -> String {
            sessionIdentifier
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
        var startFamiliars: [FamiliarIdentity?] = []
        var startSessions: [ChatSession] = []
        var resumeSessions: [ChatSession] = []

        private var startContinuation: CheckedContinuation<ChatSession, Error>?
        private var resumeContinuation: CheckedContinuation<ChatSession, Error>?

        func perform(
            _ kind: ChatModel.SessionOperationKind,
            operation: @MainActor () async throws -> ChatSession
        ) async throws -> ChatSession {
            switch kind {
            case let .start(familiar):
                startCallCount += 1
                startFamiliars.append(familiar)
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

    @MainActor
    func testSessionStoreURLResolvesApplicationSupportAliasBeforeAppendingLeaf() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-store-url-\(UUID().uuidString)", isDirectory: true)
        let applicationSupport = root
            .appendingPathComponent("real", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let alias = root.appendingPathComponent("application-support-alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: applicationSupport
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ChatModel.sessionStoreURL(applicationSupportBase: alias)
        let canonicalParent = applicationSupport
            .resolvingSymlinksInPath()
            .standardizedFileURL

        XCTAssertEqual(store.deletingLastPathComponent(), canonicalParent)
        XCTAssertEqual(
            store,
            canonicalParent.appendingPathComponent("chat-sessions", isDirectory: true)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }

    func testChatSettingsDefaultToCompanionWithoutAnAPIKey() {
        let settings = ChatSettings()
        XCTAssertEqual(settings.backend, .companionClaude)
        XCTAssertEqual(settings.model, "")
        XCTAssertEqual(settings.daemonProjectRoot, "")
        XCTAssertNil(settings.familiarID)
    }

    func testFamiliarSelectionChangesChatSettingsEquality() {
        let base = ChatSettings(
            backend: .codex,
            model: "test",
            daemonProjectRoot: "",
            familiarID: nil
        )
        var selected = base
        selected.familiarID = "sage"

        XCTAssertNotEqual(base, selected)
        XCTAssertEqual(selected, selected)
    }

    func testFamiliarResolverUsesCanonicalMatchingSnapshot() throws {
        let sage = familiarIdentity(
            id: "sage",
            name: "Sage",
            emoji: "⌁",
            role: "Research"
        )
        let settings = ChatSettings(
            backend: .codex,
            model: "test",
            daemonProjectRoot: "",
            familiarID: "SAGE"
        )

        XCTAssertEqual(
            try ChatModel.resolvedFamiliar(
                for: settings,
                selectedFamiliar: sage
            ),
            sage
        )
    }

    func testFamiliarResolverNilRouteIgnoresSelectedSnapshot() throws {
        let sage = familiarIdentity(id: "sage", name: "Sage")

        XCTAssertNil(
            try ChatModel.resolvedFamiliar(
                for: ChatSettings(backend: .codex, model: "test"),
                selectedFamiliar: sage
            )
        )
    }

    func testFamiliarResolverRejectsMissingOrMismatchedSnapshot() {
        let settings = ChatSettings(
            backend: .codex,
            model: "test",
            familiarID: "sage"
        )
        let forge = familiarIdentity(id: "forge", name: "Forge")

        for selected in [nil, forge] {
            XCTAssertThrowsError(
                try ChatModel.resolvedFamiliar(
                    for: settings,
                    selectedFamiliar: selected
                )
            ) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "The selected familiar is no longer available."
                )
            }
        }
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

    func testChatViewSharesOneCompanionModelWithFamiliarSelection() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            source.components(separatedBy: "CompanionModel()").count - 1,
            1
        )
        XCTAssertTrue(
            source.contains(
                "CompanionChatModel(companion: sharedCompanion)"
            )
        )
        XCTAssertTrue(
            source.contains(
                "FamiliarSelectionModel(companion: sharedCompanion)"
            )
        )
    }

    func testFamiliarPickerDoesNotOverrideToolsModelsOrPermissions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Views/FamiliarPickerSection.swift"
            ),
            encoding: .utf8
        )

        for forbidden in [
            "permissionMode",
            "settings.model",
            "apiKey",
            "Sage",
            "Forge",
            "Raven",
            "accessLevel",
            "toolOverride"
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertTrue(
            source.contains(
                "Familiars shape identity. They never widen iOS tools or permissions."
            )
        )
    }

    func testSessionResumeViewsKeepNextFamiliarSelectionUntouched() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sessions = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Views/SessionsView.swift"
            ),
            encoding: .utf8
        )
        let chat = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(sessions.contains("let settings: ChatSettings"))
        XCTAssertFalse(sessions.contains("@Binding var settings: ChatSettings"))
        XCTAssertTrue(sessions.contains("if await model.resume("))
        XCTAssertFalse(sessions.contains("settings = ChatModel.settingsForResume("))
        XCTAssertFalse(chat.contains("settings = ChatModel.settingsForResume("))
    }

    func testChatSupersedingActionsInvalidateSpotlightRoute() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chat = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Views/ChatSettingsView.swift"
            ),
            encoding: .utf8
        )
        let sessions = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Views/SessionsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(chat.contains("private func startSend"))
        XCTAssertTrue(chat.contains("routeCoordinator.invalidate()"))
        XCTAssertTrue(
            chat.contains("onReset: { routeCoordinator.invalidate() }")
        )
        XCTAssertTrue(
            chat.contains("onResume: { routeCoordinator.invalidate() }")
        )
        XCTAssertTrue(settings.contains("onReset()"))
        XCTAssertTrue(sessions.contains("onResume()"))
    }

    func testChatSurfacesAlwaysSynchronizeProfileAsNextFamiliar() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chat = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Views/ChatView.swift"
            ),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Views/ChatSettingsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(chat.contains("useActiveConversation"))
        XCTAssertFalse(chat.contains("hasActiveConversation"))
        XCTAssertFalse(chat.contains("activeConversationFamiliarID"))
        XCTAssertFalse(settings.contains("useActiveConversation"))
        XCTAssertFalse(settings.contains("hasActiveConversation"))
        XCTAssertFalse(settings.contains("activeConversationFamiliarID"))
        XCTAssertTrue(chat.contains("synchronizeFamiliarProfile()"))
        XCTAssertTrue(settings.contains("synchronizeFamiliarProfile()"))
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
    func testStartSeamReceivesExactSelectedFamiliarSnapshot() async {
        let boundary = SessionBoundary()
        boundary.startSessions = [StubChatSession()]
        let model = ChatModel(performSessionOperation: boundary.perform)
        let sage = familiarIdentity(
            id: "sage",
            name: "Sage",
            emoji: "⌁",
            role: "Research"
        )
        let settings = ChatSettings(
            backend: .codex,
            model: "test",
            familiarID: "SAGE"
        )

        await model.send(
            prompt: "hello",
            settings: settings,
            selectedFamiliar: sage
        )

        XCTAssertEqual(boundary.startFamiliars, [sage])
        XCTAssertEqual(model.activeFamiliar, sage)
    }

    @MainActor
    func testNilFamiliarRouteStartsWithoutIdentity() async {
        let boundary = SessionBoundary()
        boundary.startSessions = [StubChatSession()]
        let model = ChatModel(performSessionOperation: boundary.perform)

        await model.send(
            prompt: "hello",
            settings: ChatSettings(backend: .codex, model: "test"),
            selectedFamiliar: familiarIdentity(id: "sage", name: "Sage")
        )

        XCTAssertEqual(boundary.startFamiliars.count, 1)
        XCTAssertNil(boundary.startFamiliars[0])
        XCTAssertNil(model.activeFamiliar)
    }

    @MainActor
    func testUnavailableFamiliarFailsVisiblyWithoutStartingSession() async {
        let settings = ChatSettings(
            backend: .codex,
            model: "test",
            familiarID: "sage"
        )

        for selected in [
            nil,
            familiarIdentity(id: "forge", name: "Forge")
        ] {
            let boundary = SessionBoundary()
            let model = ChatModel(performSessionOperation: boundary.perform)
            await model.send(
                prompt: "hello",
                settings: settings,
                selectedFamiliar: selected
            )

            XCTAssertEqual(boundary.startCallCount, 0)
            XCTAssertEqual(
                model.items.last?.text,
                "The selected familiar is no longer available."
            )
            XCTAssertNil(model.activeFamiliar)
            XCTAssertFalse(model.canRetry)
        }
    }

    @MainActor
    func testChangingFamiliarStartsNewSessionAndPublishesValidIdentity() async {
        let boundary = SessionBoundary()
        boundary.startSessions = [StubChatSession(), StubChatSession()]
        let model = ChatModel(performSessionOperation: boundary.perform)
        let sage = familiarIdentity(id: "sage", name: "Sage")
        let forge = familiarIdentity(id: "forge", name: "Forge")

        await model.send(
            prompt: "first",
            settings: ChatSettings(
                backend: .codex,
                model: "test",
                familiarID: "sage"
            ),
            selectedFamiliar: sage
        )
        XCTAssertEqual(model.activeFamiliar, sage)

        await model.send(
            prompt: "second",
            settings: ChatSettings(
                backend: .codex,
                model: "test",
                familiarID: "forge"
            ),
            selectedFamiliar: forge
        )

        XCTAssertEqual(boundary.startFamiliars, [sage, forge])
        XCTAssertEqual(model.activeFamiliar, forge)
    }

    @MainActor
    func testFailedFamiliarReplacementCannotRetryPreviousSession() async {
        enum StartFailure: LocalizedError {
            case failed

            var errorDescription: String? { "Start failed." }
        }

        var starts = 0
        let model = ChatModel { kind, _ in
            switch kind {
            case .resume:
                return StubChatSession()
            case .start:
                starts += 1
                if starts == 1 {
                    return StubChatSession()
                }
                throw StartFailure.failed
            }
        }
        let sage = familiarIdentity(id: "sage", name: "Sage")
        let forge = familiarIdentity(id: "forge", name: "Forge")
        await model.send(
            prompt: "first",
            settings: ChatSettings(
                backend: .codex,
                model: "test",
                familiarID: "sage"
            ),
            selectedFamiliar: sage
        )

        await model.send(
            prompt: "second",
            settings: ChatSettings(
                backend: .codex,
                model: "test",
                familiarID: "forge"
            ),
            selectedFamiliar: forge
        )

        XCTAssertEqual(model.activeFamiliar, sage)
        XCTAssertEqual(model.items.last?.text, "Start failed.")
        XCTAssertFalse(model.canRetry)
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
        XCTAssertNil(model.activeFamiliar)

        boundary.finishStart(with: StubChatSession())
        await staleSend.value
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.activeFamiliar)

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
        let summary = makeSummary(
            familiar: familiarIdentity(id: "sage", name: "Sage")
        )
        let resumeSettings = ChatSettings(
            backend: .codex,
            model: "resume",
            daemonProjectRoot: "",
            familiarID: "forge"
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
        let staleResumeSucceeded = await resume.value
        XCTAssertFalse(staleResumeSucceeded)
        XCTAssertTrue(model.isBusy, "a stale resume must not finish the newer send")
        XCTAssertTrue(model.items.isEmpty, "a stale resume must not restore its transcript")
        XCTAssertNil(model.activeFamiliar)
        XCTAssertEqual(resumeSettings.familiarID, "forge")

        boundary.finishStart(with: StubChatSession())
        await freshSend.value
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(boundary.resumeCallCount, 1)
        XCTAssertEqual(boundary.startCallCount, 1)
        XCTAssertEqual(model.items.map(\.text), ["fresh"])
    }

    @MainActor
    func testResumePublishesSummaryFamiliarAndPinsSettings() async {
        let boundary = SessionBoundary()
        boundary.resumeSessions = [StubChatSession()]
        let model = ChatModel(performSessionOperation: boundary.perform)
        let sage = familiarIdentity(id: "sage", name: "Sage")
        let summary = makeSummary(familiar: sage)
        let current = ChatSettings(
            backend: .codex,
            model: "test",
            familiarID: "forge"
        )

        let resumed = await model.resume(summary, settings: current)
        XCTAssertTrue(resumed)

        XCTAssertEqual(model.activeFamiliar, sage)
        XCTAssertEqual(
            ChatModel.settingsForResume(summary, current: current).familiarID,
            "sage"
        )
        var latest = current
        latest.model = "new-model"
        latest.daemonProjectRoot = "/new/root"
        let updated = ChatModel.settingsForResume(summary, current: latest)
        XCTAssertEqual(updated.model, "new-model")
        XCTAssertEqual(updated.daemonProjectRoot, "/new/root")
    }

    @MainActor
    func testSelectingLiveSessionAgainSucceedsWithoutAnotherEngineResume() async {
        let boundary = SessionBoundary()
        boundary.resumeSessions = [
            StubChatSession(transcript: [
                ChatMessage(role: "assistant", text: "preserved transcript")
            ])
        ]
        let model = ChatModel(performSessionOperation: boundary.perform)
        let sage = familiarIdentity(id: "sage", name: "Sage")
        let summary = makeSummary(familiar: sage)
        let originalSettings = ChatSettings(
            backend: .codex,
            model: "original",
            familiarID: "forge"
        )

        let firstResume = await model.resume(summary, settings: originalSettings)
        XCTAssertTrue(firstResume)
        let preservedItemIDs = model.items.map(\.id)
        let preservedItemTexts = model.items.map(\.text)
        let preservedFamiliar = model.activeFamiliar

        let replacementSettings = ChatSettings(
            backend: .codex,
            model: "replacement",
            familiarID: nil
        )
        let secondResume = await model.resume(summary, settings: replacementSettings)
        XCTAssertTrue(secondResume)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(boundary.resumeCallCount, 1)
        XCTAssertEqual(model.items.map(\.id), preservedItemIDs)
        XCTAssertEqual(model.items.map(\.text), preservedItemTexts)
        XCTAssertEqual(model.activeFamiliar, preservedFamiliar)

        boundary.startSessions = [StubChatSession()]
        await model.send(
            prompt: "continue",
            settings: originalSettings,
            selectedFamiliar: familiarIdentity(id: "forge", name: "Forge")
        )
        XCTAssertEqual(boundary.startCallCount, 0)
    }

    @MainActor
    func testSelectingLiveSessionWhileReplacementIsBusyReturnsFalse() async {
        let boundary = SessionBoundary()
        let summaryA = makeSummary()
        boundary.resumeSessions = [
            StubChatSession(sessionIdentifier: summaryA.sessionId)
        ]
        let model = ChatModel(performSessionOperation: boundary.perform)
        let settingsA = ChatSettings(
            backend: .codex,
            model: "session-a"
        )

        let installed = await model.resume(summaryA, settings: settingsA)
        XCTAssertTrue(installed)
        XCTAssertEqual(boundary.resumeCallCount, 1)

        let sessionB = StubChatSession(sessionIdentifier: "session-b")
        boundary.suspendNextStart = true
        let replacement = Task {
            await model.send(
                prompt: "replace",
                settings: ChatSettings(
                    backend: .codex,
                    model: "session-b"
                )
            )
        }
        await fulfillment(of: [boundary.startRequested], timeout: 1)
        XCTAssertTrue(model.isBusy)

        let selectedA = await model.resume(summaryA, settings: settingsA)
        XCTAssertFalse(selectedA)
        XCTAssertEqual(boundary.resumeCallCount, 1)

        boundary.finishStart(with: sessionB)
        await replacement.value

        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.activeSessionID, "session-b")
        XCTAssertEqual(model.items.map(\.text), ["replace"])
    }

    @MainActor
    func testIdentitylessResumeReusesSessionThenFreshStartUsesSelectedForge() async {
        let boundary = SessionBoundary()
        boundary.resumeSessions = [StubChatSession()]
        boundary.startSessions = [StubChatSession()]
        let model = ChatModel(performSessionOperation: boundary.perform)
        let forge = familiarIdentity(id: "forge", name: "Forge")
        let nextSettings = ChatSettings(
            backend: .codex,
            model: "test",
            familiarID: "forge"
        )

        let resumed = await model.resume(
            makeSummary(familiar: nil),
            settings: nextSettings
        )
        XCTAssertTrue(resumed)
        await model.send(
            prompt: "continue",
            settings: nextSettings,
            selectedFamiliar: forge
        )

        XCTAssertEqual(boundary.startCallCount, 0)
        XCTAssertNil(model.activeFamiliar)

        var changedSettings = nextSettings
        changedSettings.model = "new-model"
        await model.send(
            prompt: "fresh",
            settings: changedSettings,
            selectedFamiliar: forge
        )

        XCTAssertEqual(boundary.startFamiliars, [forge])
        XCTAssertEqual(model.activeFamiliar, forge)
    }

    @MainActor
    func testSageResumeReusesSessionThenFreshStartUsesSelectedForge() async {
        let boundary = SessionBoundary()
        boundary.resumeSessions = [StubChatSession()]
        boundary.startSessions = [StubChatSession()]
        let model = ChatModel(performSessionOperation: boundary.perform)
        let sage = familiarIdentity(id: "sage", name: "Sage")
        let forge = familiarIdentity(id: "forge", name: "Forge")
        let nextSettings = ChatSettings(
            backend: .codex,
            model: "test",
            familiarID: "forge"
        )

        let resumed = await model.resume(
            makeSummary(familiar: sage),
            settings: nextSettings
        )
        XCTAssertTrue(resumed)
        await model.send(
            prompt: "continue",
            settings: nextSettings,
            selectedFamiliar: forge
        )

        XCTAssertEqual(boundary.startCallCount, 0)
        XCTAssertEqual(model.activeFamiliar, sage)

        var changedSettings = nextSettings
        changedSettings.model = "new-model"
        await model.send(
            prompt: "fresh",
            settings: changedSettings,
            selectedFamiliar: forge
        )

        XCTAssertEqual(boundary.startFamiliars, [forge])
        XCTAssertEqual(model.activeFamiliar, forge)
    }

    @MainActor
    func testSpotlightPreparationResumesSageAndReusesWithForgeSettings() async throws {
        let preparation = try makeSpotlightResumePreparation(modelName: "")
        defer {
            preparation.defaults.removePersistentDomain(
                forName: preparation.suiteName
            )
        }

        XCTAssertEqual(preparation.settings.backend, .codex)
        XCTAssertEqual(preparation.settings.model, "codex-default")
        XCTAssertEqual(preparation.settings.familiarID, "forge")
        XCTAssertEqual(
            preparation.familiarModel.activeProfile,
            preparation.codexProfile
        )
        XCTAssertEqual(
            preparation.familiarModel.selectedFamiliar,
            preparation.forge
        )

        let boundary = SessionBoundary()
        boundary.resumeSessions = [StubChatSession()]
        let model = ChatModel(performSessionOperation: boundary.perform)
        let sage = familiarIdentity(id: "sage", name: "Sage")

        let resumed = await model.resume(
            makeSummary(familiar: sage),
            settings: preparation.settings
        )
        XCTAssertTrue(resumed)
        await model.send(
            prompt: "continue",
            settings: preparation.settings,
            selectedFamiliar: preparation.familiarModel.selectedFamiliar
        )

        XCTAssertEqual(boundary.resumeCallCount, 1)
        XCTAssertEqual(boundary.startCallCount, 0)
        XCTAssertEqual(model.activeFamiliar, sage)
        XCTAssertEqual(
            try preparation.store.load(for: preparation.codexProfile),
            preparation.forge
        )
    }

    @MainActor
    func testSpotlightPreparationResumesIdentitylessAndReusesWithForgeSettings() async throws {
        let preparation = try makeSpotlightResumePreparation(
            modelName: "codex-current"
        )
        defer {
            preparation.defaults.removePersistentDomain(
                forName: preparation.suiteName
            )
        }

        let boundary = SessionBoundary()
        boundary.resumeSessions = [StubChatSession()]
        let model = ChatModel(performSessionOperation: boundary.perform)

        let resumed = await model.resume(
            makeSummary(familiar: nil),
            settings: preparation.settings
        )
        XCTAssertTrue(resumed)
        await model.send(
            prompt: "continue",
            settings: preparation.settings,
            selectedFamiliar: preparation.familiarModel.selectedFamiliar
        )

        XCTAssertEqual(preparation.settings.backend, .codex)
        XCTAssertEqual(preparation.settings.model, "codex-current")
        XCTAssertEqual(preparation.settings.familiarID, "forge")
        XCTAssertEqual(boundary.resumeCallCount, 1)
        XCTAssertEqual(boundary.startCallCount, 0)
        XCTAssertNil(model.activeFamiliar)
        XCTAssertEqual(
            preparation.familiarModel.activeProfile,
            preparation.codexProfile
        )
        XCTAssertEqual(
            try preparation.store.load(for: preparation.codexProfile),
            preparation.forge
        )
    }

    @MainActor
    func testOlderSpotlightLookupCannotResumeAfterNewerRouteBegins() async {
        let coordinator = ChatRouteGenerationCoordinator()
        let lookupRequested = XCTestExpectation(
            description: "older Spotlight lookup requested"
        )
        var lookupContinuation: CheckedContinuation<Int?, Never>?
        var resumed: [Int] = []
        let olderToken = coordinator.begin()
        let older = Task {
            await SpotlightSessionRouteRunner.run(
                token: olderToken,
                coordinator: coordinator,
                lookup: {
                    lookupRequested.fulfill()
                    return await withCheckedContinuation { continuation in
                        lookupContinuation = continuation
                    }
                },
                cancelResume: {},
                resume: { resumed.append($0) }
            )
        }
        await fulfillment(of: [lookupRequested], timeout: 1)

        let newerToken = coordinator.begin()
        await SpotlightSessionRouteRunner.run(
            token: newerToken,
            coordinator: coordinator,
            lookup: { 2 },
            cancelResume: {},
            resume: { resumed.append($0) }
        )
        lookupContinuation?.resume(returning: 1)
        await older.value

        XCTAssertEqual(resumed, [2])
        XCTAssertFalse(coordinator.isCurrent(olderToken))
        XCTAssertFalse(coordinator.isCurrent(newerToken))
    }

    @MainActor
    func testSupersedingSendInvalidatesSuspendedSpotlightLookup() async {
        let coordinator = ChatRouteGenerationCoordinator()
        let lookupRequested = XCTestExpectation(
            description: "Spotlight lookup requested"
        )
        var lookupContinuation: CheckedContinuation<Int?, Never>?
        var resumeCount = 0
        let token = coordinator.begin()
        let route = Task {
            await SpotlightSessionRouteRunner.run(
                token: token,
                coordinator: coordinator,
                lookup: {
                    lookupRequested.fulfill()
                    return await withCheckedContinuation { continuation in
                        lookupContinuation = continuation
                    }
                },
                cancelResume: {},
                resume: { _ in resumeCount += 1 }
            )
        }
        await fulfillment(of: [lookupRequested], timeout: 1)

        coordinator.invalidate()
        lookupContinuation?.resume(returning: 1)
        await route.value

        XCTAssertEqual(resumeCount, 0)
    }

    @MainActor
    func testUnavailableQueuedPromptInvalidatesSuspendedSpotlightLookup() async {
        let coordinator = ChatRouteGenerationCoordinator()
        let lookupRequested = XCTestExpectation(
            description: "Spotlight lookup requested before queued prompt"
        )
        var lookupContinuation: CheckedContinuation<Int?, Never>?
        var prompt = ""
        var resumeCount = 0
        let token = coordinator.begin()
        let route = Task {
            await SpotlightSessionRouteRunner.run(
                token: token,
                coordinator: coordinator,
                lookup: {
                    lookupRequested.fulfill()
                    return await withCheckedContinuation { continuation in
                        lookupContinuation = continuation
                    }
                },
                cancelResume: {},
                resume: { _ in resumeCount += 1 }
            )
        }
        await fulfillment(of: [lookupRequested], timeout: 1)

        let queuedForSend = ChatView.consumeQueuedPrompt(
            "Explain this session",
            coordinator: coordinator,
            stage: { prompt = $0 },
            canSend: {
                XCTAssertFalse(coordinator.isCurrent(token))
                return false
            }
        )
        lookupContinuation?.resume(returning: 1)
        await route.value

        XCTAssertNil(queuedForSend)
        XCTAssertEqual(prompt, "Explain this session")
        XCTAssertEqual(resumeCount, 0)
    }

    @MainActor
    func testResetDuringSpotlightLookupBlocksStaleResume() async {
        let coordinator = ChatRouteGenerationCoordinator()
        let lookupRequested = XCTestExpectation(
            description: "Spotlight lookup requested before reset"
        )
        var lookupContinuation: CheckedContinuation<Int?, Never>?
        var resumeCount = 0
        let token = coordinator.begin()
        let route = Task {
            await SpotlightSessionRouteRunner.run(
                token: token,
                coordinator: coordinator,
                lookup: {
                    lookupRequested.fulfill()
                    return await withCheckedContinuation { continuation in
                        lookupContinuation = continuation
                    }
                },
                cancelResume: {},
                resume: { _ in resumeCount += 1 }
            )
        }
        await fulfillment(of: [lookupRequested], timeout: 1)

        coordinator.invalidate()
        lookupContinuation?.resume(returning: 1)
        await route.value

        XCTAssertEqual(resumeCount, 0)
        XCTAssertFalse(coordinator.isCurrent(token))
    }

    @MainActor
    func testInvalidationCancelsSpotlightResumeAlreadyInFlight() async {
        let coordinator = ChatRouteGenerationCoordinator()
        let resumeRequested = XCTestExpectation(
            description: "Spotlight resume requested"
        )
        var resumeContinuation: CheckedContinuation<Void, Never>?
        var cancellationCount = 0
        let token = coordinator.begin()
        let route = Task {
            await SpotlightSessionRouteRunner.run(
                token: token,
                coordinator: coordinator,
                lookup: { 1 },
                cancelResume: { cancellationCount += 1 },
                resume: { _ in
                    resumeRequested.fulfill()
                    await withCheckedContinuation { continuation in
                        resumeContinuation = continuation
                    }
                }
            )
        }
        await fulfillment(of: [resumeRequested], timeout: 1)

        coordinator.invalidate()
        resumeContinuation?.resume()
        await route.value

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(coordinator.isCurrent(token))
    }

    @MainActor
    func testMissingSpotlightLookupRetiresCurrentToken() async {
        let coordinator = ChatRouteGenerationCoordinator()
        let token = coordinator.begin()
        var resumeCount = 0

        await SpotlightSessionRouteRunner.run(
            token: token,
            coordinator: coordinator,
            lookup: { Optional<Int>.none },
            cancelResume: {},
            resume: { _ in resumeCount += 1 }
        )

        XCTAssertEqual(resumeCount, 0)
        XCTAssertFalse(coordinator.isCurrent(token))
    }

    @MainActor
    func testFailedResumeReturnsFalseWithoutPublishingFamiliar() async {
        enum ResumeFailure: LocalizedError {
            case failed

            var errorDescription: String? { "Resume failed." }
        }

        let model = ChatModel { kind, _ in
            switch kind {
            case .resume:
                throw ResumeFailure.failed
            case .start:
                return StubChatSession()
            }
        }
        let summary = makeSummary(
            familiar: familiarIdentity(id: "sage", name: "Sage")
        )
        let nextSettings = ChatSettings(
            backend: .codex,
            model: "test",
            familiarID: "forge"
        )

        let resumed = await model.resume(
            summary,
            settings: nextSettings
        )
        XCTAssertFalse(resumed)
        XCTAssertEqual(nextSettings.familiarID, "forge")
        XCTAssertNil(model.activeFamiliar)
        XCTAssertEqual(model.items.last?.text, "Resume failed.")
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
        updatedAt: String = "2026-01-02T03:04:05+00:00",
        familiar: FamiliarIdentity? = nil
    ) -> ChatSessionSummary {
        ChatSessionSummary(
            sessionId: UUID().uuidString.lowercased(),
            title: title,
            model: "claude-test",
            createdAt: "2026-01-01T00:00:00+00:00",
            updatedAt: updatedAt,
            messageCount: 2,
            familiar: familiar
        )
    }

    @MainActor
    private func makeSpotlightResumePreparation(
        modelName: String
    ) throws -> SpotlightResumePreparation {
        let suiteName = "spotlight-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = FamiliarSelectionStore(defaults: defaults)
        let companionProfile = FamiliarProfileKey.companion(
            host: "mac.local",
            port: 7001
        )
        let codexProfile = FamiliarProfileKey.codex(profileID: "profile-a")
        let owl = familiarIdentity(id: "owl", name: "Owl")
        let forge = familiarIdentity(id: "forge", name: "Forge")
        try store.save(owl, for: companionProfile)
        try store.save(forge, for: codexProfile)
        let familiarModel = FamiliarSelectionModel(
            client: NoopFamiliarRosterClient(),
            store: store
        )
        familiarModel.activate(companionProfile)
        let prepared = try XCTUnwrap(
            ChatFamiliarProfile.settingsForCodexResume(
                current: ChatSettings(
                    backend: .companionClaude,
                    model: modelName,
                    daemonProjectRoot: "/companion",
                    familiarID: "owl"
                ),
                codexProfileID: "profile-a",
                defaultModel: "codex-default",
                model: familiarModel
            )
        )
        return SpotlightResumePreparation(
            suiteName: suiteName,
            defaults: defaults,
            store: store,
            familiarModel: familiarModel,
            settings: prepared,
            codexProfile: codexProfile,
            forge: forge
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

    private func familiarIdentity(
        id: String,
        name: String,
        emoji: String? = nil,
        role: String? = nil
    ) -> FamiliarIdentity {
        FamiliarIdentity(
            id: id,
            displayName: name,
            emoji: emoji,
            role: role
        )
    }

    func testSummaryDisplayTitleFallsBack() {
        XCTAssertEqual(makeSummary(title: "Fix the bug").displayTitle, "Fix the bug")
        XCTAssertEqual(makeSummary(title: "").displayTitle, "Untitled session")
        let summary = makeSummary()
        XCTAssertEqual(summary.id, summary.sessionId)
    }
}
