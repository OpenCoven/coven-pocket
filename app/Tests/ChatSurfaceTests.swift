import Combine
import XCTest
import SwiftUI
import UIKit
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

private final class ChatSurfacePairingStore: PairingStore {
    var stored: DaemonPairing?

    init(stored: DaemonPairing?) {
        self.stored = stored
    }

    func load() -> DaemonPairing? {
        stored
    }

    func save(_ pairing: DaemonPairing) {
        stored = pairing
    }

    func clear() {
        stored = nil
    }
}

// swiftlint:disable:next type_body_length
final class ChatSurfaceTests: XCTestCase {
    private struct AccountTransitionFamiliarFixture {
        let suiteName: String
        let defaults: UserDefaults
        let store: FamiliarSelectionStore
        let model: FamiliarSelectionModel
        let profileA: FamiliarProfileKey
        let profileB: FamiliarProfileKey
        let sage: FamiliarIdentity
        let forge: FamiliarIdentity
    }

    private struct HostedRootTransitionFixture {
        let familiar: AccountTransitionFamiliarFixture
        let boundary: SessionBoundary
        let chatModel: ChatModel
        let routes: ChatRouteGenerationCoordinator
        let staleRoute: ChatRouteGenerationCoordinator.Token
        let chatState: ChatSurfaceState
        let client: EngineClient
        let previousTab: AppRouter.Tab
        let window: UIWindow

        @MainActor
        func cleanup() {
            familiar.defaults.removePersistentDomain(
                forName: familiar.suiteName
            )
            AppRouter.shared.selectedTab = previousTab
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private struct HostedRoutedResetFixture {
        let suiteName: String
        let defaults: UserDefaults
        let pairing: DaemonPairing
        let remoteClient: FakeCompanionSessionClient
        let companionChat: CompanionChatModel
        let router: AppRouter
        let previousTab: AppRouter.Tab
        let window: UIWindow

        @MainActor
        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            router.selectedTab = previousTab
            _ = router.consumePrompt()
            _ = router.consumeSessionID()
            _ = router.consumeReset()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private struct SpotlightResumePreparation {
        let suiteName: String
        let defaults: UserDefaults
        let store: FamiliarSelectionStore
        let familiarModel: FamiliarSelectionModel
        let settings: ChatSettings
        let codexProfile: FamiliarProfileKey
        let forge: FamiliarIdentity
    }

    private struct WindowAccountFixture {
        let suiteName: String
        let defaults: UserDefaults
        let boundary: SessionBoundary
        let model: ChatModel
        let routes: ChatRouteGenerationCoordinator
        let companionClient: FakeCompanionSessionClient
        let companionModel: CompanionChatModel
        let chatState: ChatSurfaceState

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private struct WindowTransitionResult {
        let firstWindow: RootWindowState
        let secondWindow: RootWindowState
        let client: EngineClient
        let firstSession: TrackingChatSession
        let lateSecondSession: TrackingChatSession
        let firstRoute: ChatRouteGenerationCoordinator.Token
        let secondRoute: ChatRouteGenerationCoordinator.Token
    }

    private final class SuspendedAuthEngine: PocketEngine, @unchecked Sendable {
        let loginStarted = XCTestExpectation(description: "Codex login started")

        private let lock = NSLock()
        private var loginCalls = 0
        private var loginContinuations: [CheckedContinuation<Void, Never>] = []

        var loginCallCount: Int {
            lock.withLock { loginCalls }
        }

        init() {
            super.init(noHandle: PocketEngine.NoHandle())
        }

        required init(unsafeFromHandle handle: UInt64) {
            super.init(unsafeFromHandle: handle)
        }

        override func codexAccount() -> CodexAccount? {
            nil
        }

        override func codexLogin(delegate: CodexAuthDelegate) async throws -> CodexAccount {
            let callCount = lock.withLock {
                loginCalls += 1
                return loginCalls
            }
            await withCheckedContinuation { continuation in
                lock.withLock {
                    loginContinuations.append(continuation)
                }
                if callCount == 1 {
                    loginStarted.fulfill()
                }
            }
            return CodexAccount(
                profileId: "profile-b",
                email: "b@example.com",
                accountId: nil
            )
        }

        override func listCodexModels() async throws -> [PocketModel] {
            []
        }

        func finishLogins() {
            let continuations = lock.withLock {
                let pending = loginContinuations
                loginContinuations.removeAll()
                return pending
            }
            continuations.forEach { $0.resume() }
        }
    }

    private final class SuspendedCodexModelsEngine: PocketEngine, @unchecked Sendable {
        let modelLoadStarted = XCTestExpectation(
            description: "Codex model load started"
        )

        private let lock = NSLock()
        private var pendingContinuation: CheckedContinuation<[PocketModel], Never>?

        init() {
            super.init(noHandle: PocketEngine.NoHandle())
        }

        required init(unsafeFromHandle handle: UInt64) {
            super.init(unsafeFromHandle: handle)
        }

        override func codexAccount() -> CodexAccount? {
            nil
        }

        override func listCodexModels() async throws -> [PocketModel] {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    pendingContinuation = continuation
                }
                modelLoadStarted.fulfill()
            }
        }

        func finishModelLoad(with models: [PocketModel]) {
            let continuation = lock.withLock {
                let pending = pendingContinuation
                pendingContinuation = nil
                return pending
            }
            continuation?.resume(returning: models)
        }
    }

    @MainActor
    func testRootSectionConstructionSharesOneEngineClient() {
        let client = EngineClient()
        let root = RootView(client: client)

        XCTAssertTrue(root.sectionFactory.chat().client === client)
        XCTAssertTrue(root.sectionFactory.playground().client === client)
    }

    @MainActor
    func testAppFactoryInjectsOneEngineClientAndCreatesPerWindowChatState() {
        let client = EngineClient(engine: SuspendedAuthEngine())
        let app = CovenPocketApp(
            dependencies: CovenPocketAppDependencies(engineClient: client)
        )

        let first = app.rootWindowFactory.makeWindowState()
        let second = app.rootWindowFactory.makeWindowState()

        XCTAssertTrue(first.client === client)
        XCTAssertTrue(second.client === client)
        XCTAssertTrue(
            first.sectionFactory.client === second.sectionFactory.client
        )
        XCTAssertFalse(
            first.chatState === second.chatState
        )
    }

    func testAppBodyUsesStableRootWindowState() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/CovenPocketApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("@StateObject private var rootWindowState")
        )
        XCTAssertTrue(
            source.contains("RootView(windowState: rootWindowState)")
        )
        XCTAssertFalse(source.contains("rootWindowFactory.makeRoot()"))
    }

    func testSidebarRoutesSessionDeletionThroughSharedChatModel() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/Views/RootView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("chatModel: windowState.chatState.model")
        )
        XCTAssertFalse(source.contains("SidebarSessionsModel()"))
    }

    @MainActor
    func testStandaloneRootInitializerIsExplicit() {
        let client = EngineClient(engine: SuspendedAuthEngine())

        _ = RootView(standaloneClient: client)
    }

    @MainActor
    func testSharedAccountTransitionResetsBothWindowsAndPreservesCompanion() async throws {
        let first = try await makeWindowAccountFixture(suspendsOnDeviceStart: false)
        let second = try await makeWindowAccountFixture(suspendsOnDeviceStart: true)
        defer {
            first.cleanup()
            second.cleanup()
        }
        let transition = await performSharedAccountTransition(
            first: first,
            second: second
        )

        assertAccountTransitionReset(
            first: first,
            second: second,
            transition: transition
        )
        await assertSameProfilePreservesWindows(
            first: first,
            second: second,
            client: transition.client
        )
    }

    @MainActor
    func testAccountObserversDeliverOneTransitionPerWindow() {
        let client = EngineClient(engine: SuspendedAuthEngine())
        client.codexAccount = CodexAccount(
            profileId: "profile-a",
            email: nil,
            accountId: nil
        )
        var firstTransitions: [(String?, String?)] = []
        var secondTransitions: [(String?, String?)] = []
        let first = CodexAccountTransitionObserver(client: client) {
            firstTransitions.append(($0, $1))
        }
        let second = CodexAccountTransitionObserver(client: client) {
            secondTransitions.append(($0, $1))
        }

        client.codexAccount = CodexAccount(
            profileId: "profile-b",
            email: nil,
            accountId: nil
        )
        client.codexAccount = CodexAccount(
            profileId: "profile-b",
            email: "same-profile@example.com",
            accountId: nil
        )

        XCTAssertEqual(firstTransitions.count, 1)
        XCTAssertEqual(secondTransitions.count, 1)
        XCTAssertEqual(firstTransitions.first?.0, "profile-a")
        XCTAssertEqual(firstTransitions.first?.1, "profile-b")
        XCTAssertEqual(secondTransitions.first?.0, "profile-a")
        XCTAssertEqual(secondTransitions.first?.1, "profile-b")
        withExtendedLifetime((first, second)) {}
    }

    @MainActor
    func testNewWindowAfterAccountChangeStartsFreshOnCurrentAccount() async throws {
        let oldWindow = try await makeWindowAccountFixture(
            suspendsOnDeviceStart: false
        )
        defer { oldWindow.cleanup() }
        let oldSession = TrackingChatSession()
        oldWindow.boundary.startSessions = [oldSession]
        await oldWindow.model.send(
            prompt: "account A",
            settings: oldWindow.chatState.settings
        )
        let client = EngineClient(engine: SuspendedAuthEngine())
        client.codexAccount = CodexAccount(
            profileId: "profile-a",
            email: nil,
            accountId: nil
        )
        let app = CovenPocketApp(
            dependencies: CovenPocketAppDependencies(engineClient: client)
        )
        let oldRoot = app.rootWindowFactory.makeWindowState(
            chatState: oldWindow.chatState
        )

        client.codexAccount = CodexAccount(
            profileId: "profile-b",
            email: nil,
            accountId: nil
        )
        let newRoot = app.rootWindowFactory.makeWindowState()

        XCTAssertEqual(oldSession.stopCallCount, 1)
        XCTAssertEqual(
            newRoot.client.codexAccount?.profileId,
            "profile-b"
        )
        XCTAssertFalse(
            newRoot.chatState === oldRoot.chatState
        )
        XCTAssertFalse(newRoot.chatState.model.hasActiveSession)
        XCTAssertTrue(newRoot.chatState.model.items.isEmpty)
    }

    @MainActor
    func testSharedAuthenticationFenceStartsOnlyOneLogin() async {
        let engine = SuspendedAuthEngine()
        let client = EngineClient(engine: engine)
        let app = CovenPocketApp(
            dependencies: CovenPocketAppDependencies(engineClient: client)
        )
        let firstPlayground = app.rootWindowFactory.makeWindowState()
            .sectionFactory.playground()
        let secondPlayground = app.rootWindowFactory.makeWindowState()
            .sectionFactory.playground()
        XCTAssertTrue(firstPlayground.client === secondPlayground.client)

        let firstLogin = Task { await client.codexLogin() }
        await fulfillment(of: [engine.loginStarted], timeout: 1)
        let secondLogin = Task { await client.codexLogin() }
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertTrue(client.isAuthenticating)
        XCTAssertEqual(engine.loginCallCount, 1)
        engine.finishLogins()
        await firstLogin.value
        await secondLogin.value
        XCTAssertFalse(client.isAuthenticating)
        XCTAssertEqual(client.codexAccount?.profileId, "profile-b")
    }

    @MainActor
    func testWindowsDoNotPublishPersistedStaleAccountDuringCleanupFailure() {
        let engine = ControllableEngineClientEngine(
            account: CodexAccount(
                profileId: "profile-a",
                email: "a@example.com",
                accountId: nil
            )
        )
        engine.failNextLogouts(1)
        let store = TestAuthenticationCleanupStore(cleanupRequired: true)
        let client = EngineClient(
            engine: engine,
            authenticationCleanupStore: store
        )
        let app = CovenPocketApp(
            dependencies: CovenPocketAppDependencies(engineClient: client)
        )

        let first = app.rootWindowFactory.makeWindowState()
        let second = app.rootWindowFactory.makeWindowState()

        XCTAssertTrue(first.client === second.client)
        XCTAssertNil(first.client.codexAccount)
        XCTAssertNil(second.client.codexAccount)
        XCTAssertTrue(client.authenticationCleanupRequired)
        XCTAssertNotNil(client.authenticationCleanupError)
        XCTAssertEqual(engine.codexAccountCallCount, 0)
    }

    @MainActor
    func testAccountChangeClearsModelsAndDropsPreviousProfileLoad() async {
        let engine = SuspendedCodexModelsEngine()
        let client = EngineClient(engine: engine)
        client.codexAccount = CodexAccount(
            profileId: "profile-a",
            email: nil,
            accountId: nil
        )
        client.codexModels = [pocketModel(id: "profile-a-model")]
        let load = Task { await client.loadCodexModels() }
        await fulfillment(of: [engine.modelLoadStarted], timeout: 1)

        client.codexAccount = CodexAccount(
            profileId: "profile-b",
            email: nil,
            accountId: nil
        )
        engine.finishModelLoad(with: [pocketModel(id: "stale-profile-a-model")])
        await load.value

        XCTAssertTrue(client.codexModels.isEmpty)
    }

    @MainActor
    func testRootTransitionFencesChatWorkWhileChatSectionIsUnmounted() async throws {
        let fixture = try makeHostedRootTransitionFixture()
        defer { fixture.cleanup() }
        let pendingSend = Task {
            await fixture.chatModel.send(
                prompt: "account A",
                settings: fixture.chatState.settings,
                selectedFamiliar: fixture.familiar.sage
            )
        }
        await fulfillment(of: [fixture.boundary.startRequested], timeout: 1)
        let lateSession = TrackingChatSession()
        AppRouter.shared.selectedTab = .playground
        await Task.yield()

        let transitioned = expectation(description: "root handled account transition")
        let transitionObservation = fixture.chatState.$settings
            .dropFirst()
            .sink { updated in
                if !fixture.routes.isCurrent(fixture.staleRoute),
                   updated.familiarID == fixture.familiar.forge.id {
                    transitioned.fulfill()
                }
            }
        fixture.client.codexAccount = CodexAccount(
            profileId: "profile-b",
            email: "b@example.com",
            accountId: nil
        )
        await fulfillment(of: [transitioned], timeout: 1)
        transitionObservation.cancel()
        fixture.boundary.finishStart(with: lateSession)
        await pendingSend.value

        XCTAssertEqual(lateSession.stopCallCount, 1)
        XCTAssertFalse(fixture.routes.isCurrent(fixture.staleRoute))
        XCTAssertFalse(fixture.chatModel.hasActiveSession)
        XCTAssertTrue(fixture.chatModel.items.isEmpty)
        XCTAssertEqual(fixture.familiar.model.activeProfile, fixture.familiar.profileB)
        XCTAssertEqual(fixture.chatState.settings.familiarID, fixture.familiar.forge.id)
    }

    @MainActor
    func testAccountAToBInvalidatesRouteResetsOnceAndRestoresBFamiliar() async throws {
        let fixture = try makeAccountTransitionFamiliarFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        var settings = ChatSettings(
            backend: .codex,
            model: "test",
            familiarID: fixture.sage.id
        )

        let session = TrackingChatSession()
        let boundary = SessionBoundary()
        boundary.startSessions = [session]
        let chatModel = ChatModel(performSessionOperation: boundary.perform)
        await chatModel.send(
            prompt: "account A", settings: settings,
            selectedFamiliar: fixture.sage
        )
        let routes = ChatRouteGenerationCoordinator()
        let staleRoute = routes.begin()
        var resetCount = 0
        var callOrder: [String] = []

        CodexAccountTransitionCoordinator.handle(
            from: "profile-a",
            to: "profile-b",
            invalidateRoutes: {
                callOrder.append("route")
                routes.invalidate()
            },
            resetOnDevice: {
                callOrder.append("reset")
                resetCount += 1
                chatModel.reset()
            },
            synchronizeFamiliar: {
                callOrder.append("familiar")
                settings.familiarID = ChatFamiliarProfile.synchronize(
                    fixture.profileB,
                    model: fixture.model
                )
            }
        )

        XCTAssertEqual(callOrder, ["route", "reset", "familiar"])
        XCTAssertEqual(resetCount, 1)
        XCTAssertFalse(routes.isCurrent(staleRoute))
        XCTAssertFalse(chatModel.hasActiveSession)
        XCTAssertTrue(chatModel.items.isEmpty)
        XCTAssertNil(chatModel.activeFamiliar)
        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertEqual(fixture.model.activeProfile, fixture.profileB)
        XCTAssertEqual(fixture.model.selectedFamiliar, fixture.forge)
        XCTAssertEqual(settings.familiarID, fixture.forge.id)
        XCTAssertEqual(try fixture.store.load(for: fixture.profileA), fixture.sage)
    }

    @MainActor
    func testAccountAToNilResetsAndClearsFamiliarState() async throws {
        let suiteName = "account-transition-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profileA = FamiliarProfileKey.codex(profileID: "profile-a")
        let sage = familiarIdentity(id: "sage", name: "Sage")
        let store = FamiliarSelectionStore(defaults: defaults)
        try store.save(sage, for: profileA)
        let familiarModel = FamiliarSelectionModel(
            client: NoopFamiliarRosterClient(),
            store: store
        )
        familiarModel.activate(profileA)
        var settings = ChatSettings(
            backend: .codex,
            model: "test",
            familiarID: sage.id
        )

        let session = TrackingChatSession()
        let boundary = SessionBoundary()
        boundary.startSessions = [session]
        let chatModel = ChatModel(performSessionOperation: boundary.perform)
        await chatModel.send(
            prompt: "account A",
            settings: settings,
            selectedFamiliar: sage
        )
        var resetCount = 0

        CodexAccountTransitionCoordinator.handle(
            from: "profile-a",
            to: nil,
            invalidateRoutes: {},
            resetOnDevice: {
                resetCount += 1
                chatModel.reset()
            },
            synchronizeFamiliar: {
                settings.familiarID = ChatFamiliarProfile.synchronize(
                    nil,
                    model: familiarModel
                )
            }
        )

        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertFalse(chatModel.hasActiveSession)
        XCTAssertTrue(chatModel.items.isEmpty)
        XCTAssertNil(chatModel.activeFamiliar)
        XCTAssertNil(familiarModel.activeProfile)
        XCTAssertNil(familiarModel.selectedFamiliar)
        XCTAssertNil(settings.familiarID)
    }

    @MainActor
    func testAccountNilToBResetsStaleAStateBeforeRestoringB() async throws {
        let suiteName = "account-transition-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profileA = FamiliarProfileKey.codex(profileID: "profile-a")
        let profileB = FamiliarProfileKey.codex(profileID: "profile-b")
        let sage = familiarIdentity(id: "sage", name: "Sage")
        let forge = familiarIdentity(id: "forge", name: "Forge")
        let store = FamiliarSelectionStore(defaults: defaults)
        try store.save(sage, for: profileA)
        try store.save(forge, for: profileB)
        let familiarModel = FamiliarSelectionModel(
            client: NoopFamiliarRosterClient(),
            store: store
        )
        familiarModel.activate(profileA)
        var settings = ChatSettings(
            backend: .codex,
            model: "test",
            familiarID: sage.id
        )

        let staleSession = TrackingChatSession()
        let boundary = SessionBoundary()
        boundary.startSessions = [staleSession]
        let chatModel = ChatModel(performSessionOperation: boundary.perform)
        await chatModel.send(
            prompt: "stale account A",
            settings: settings,
            selectedFamiliar: sage
        )

        CodexAccountTransitionCoordinator.handle(
            from: nil,
            to: "profile-b",
            invalidateRoutes: {},
            resetOnDevice: {
                chatModel.reset()
            },
            synchronizeFamiliar: {
                settings.familiarID = ChatFamiliarProfile.synchronize(
                    profileB,
                    model: familiarModel
                )
            }
        )

        XCTAssertEqual(staleSession.stopCallCount, 1)
        XCTAssertFalse(chatModel.hasActiveSession)
        XCTAssertTrue(chatModel.items.isEmpty)
        XCTAssertNil(chatModel.activeFamiliar)
        XCTAssertEqual(familiarModel.activeProfile, profileB)
        XCTAssertEqual(familiarModel.selectedFamiliar, forge)
        XCTAssertEqual(settings.familiarID, forge.id)
    }

    @MainActor
    func testSameProfileIDDoesNotResetLiveChat() async {
        let session = TrackingChatSession()
        let boundary = SessionBoundary()
        boundary.startSessions = [session]
        let chatModel = ChatModel(performSessionOperation: boundary.perform)
        let settings = ChatSettings(backend: .codex, model: "test")
        await chatModel.send(prompt: "preserve", settings: settings)
        var callbacks = 0

        CodexAccountTransitionCoordinator.handle(
            from: "profile-a",
            to: "profile-a",
            invalidateRoutes: { callbacks += 1 },
            resetOnDevice: {
                callbacks += 1
                chatModel.reset()
            },
            synchronizeFamiliar: { callbacks += 1 }
        )

        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(chatModel.hasActiveSession)
        XCTAssertEqual(chatModel.items.map(\.text), ["preserve"])
        XCTAssertEqual(session.stopCallCount, 0)
    }

    @MainActor
    func testAccountTransitionStopsLateSessionCreationWithoutAdoptingIt() async {
        let boundary = SessionBoundary()
        boundary.suspendNextStart = true
        let chatModel = ChatModel(performSessionOperation: boundary.perform)
        let settings = ChatSettings(backend: .codex, model: "test")
        let pendingSend = Task {
            await chatModel.send(prompt: "account A", settings: settings)
        }
        await fulfillment(of: [boundary.startRequested], timeout: 1)
        let lateSession = TrackingChatSession()

        CodexAccountTransitionCoordinator.handle(
            from: "profile-a",
            to: "profile-b",
            invalidateRoutes: {},
            resetOnDevice: { chatModel.reset() },
            synchronizeFamiliar: {}
        )
        boundary.finishStart(with: lateSession)
        await pendingSend.value

        XCTAssertEqual(lateSession.stopCallCount, 1)
        XCTAssertFalse(chatModel.isBusy)
        XCTAssertFalse(chatModel.hasActiveSession)
        XCTAssertTrue(chatModel.items.isEmpty)
        XCTAssertNil(chatModel.activeFamiliar)
    }

    @MainActor
    func testCodexAccountTransitionDoesNotKillActiveCompanionSession() async {
        let client = FakeCompanionSessionClient(gate: .ready(pairedDaemon()))
        let companionModel = CompanionChatModel(client: client)
        await companionModel.send(prompt: "remote", projectRoot: "/srv/repo")
        XCTAssertTrue(companionModel.hasActiveSession)

        var onDeviceResetCount = 0
        CodexAccountTransitionCoordinator.handle(
            from: "profile-a",
            to: "profile-b",
            invalidateRoutes: {},
            resetOnDevice: { onDeviceResetCount += 1 },
            synchronizeFamiliar: {}
        )

        XCTAssertEqual(onDeviceResetCount, 1)
        XCTAssertTrue(companionModel.hasActiveSession)
        XCTAssertEqual(companionModel.items.map(\.text), ["remote"])
        XCTAssertTrue(client.killedSessionIDs.isEmpty)
    }

    private final class TrackingChatSession: ChatSession, @unchecked Sendable {
        private let sessionIdentifier = UUID().uuidString
        private let lock = NSLock()
        private var stops = 0

        var stopCallCount: Int {
            lock.withLock { stops }
        }

        init() {
            super.init(noHandle: ChatSession.NoHandle())
        }

        required init(unsafeFromHandle handle: UInt64) {
            super.init(unsafeFromHandle: handle)
        }

        override func send(prompt: String, delegate: ChatDelegate) async throws {}

        override func sessionId() -> String {
            sessionIdentifier
        }

        override func stop() {
            lock.withLock {
                stops += 1
            }
        }
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
    func testSessionStoreURLCanonicalizesSyntheticVarMobilePathWithoutCreatingIt() {
        let applicationSupportPath = """
        /var/mobile/Containers/Data/Application/ABC/Library/Application Support
        """
        let applicationSupport = URL(
            fileURLWithPath: applicationSupportPath,
            isDirectory: true
        )

        let store = ChatModel.sessionStoreURL(applicationSupportBase: applicationSupport)

        XCTAssertEqual(
            store.path,
            """
            /private/var/mobile/Containers/Data/Application/ABC/Library/Application Support/\
            chat-sessions
            """
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: applicationSupport.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }

    @MainActor
    func testSessionStoreURLCanonicalizesExactVarRoot() {
        let store = ChatModel.sessionStoreURL(
            applicationSupportBase: URL(fileURLWithPath: "/var", isDirectory: true)
        )

        XCTAssertEqual(store.path, "/private/var/chat-sessions")
    }

    @MainActor
    func testSessionStoreURLLeavesOrdinaryUsersPathUnchanged() {
        let applicationSupportPath = "/Users/example/Library/Application Support"
        let store = ChatModel.sessionStoreURL(
            applicationSupportBase: URL(
                fileURLWithPath: applicationSupportPath,
                isDirectory: true
            )
        )

        XCTAssertEqual(store.path, "\(applicationSupportPath)/chat-sessions")
    }

    @MainActor
    func testSessionStoreURLCanonicalizesAppleSystemAliasesAtComponentBoundary() {
        let mappings = [
            ("/tmp/example", "/private/tmp/example/chat-sessions"),
            ("/etc/example", "/private/etc/example/chat-sessions"),
            ("/variable/example", "/variable/example/chat-sessions")
        ]

        for (input, expected) in mappings {
            let store = ChatModel.sessionStoreURL(
                applicationSupportBase: URL(fileURLWithPath: input, isDirectory: true)
            )
            XCTAssertEqual(store.path, expected)
        }
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

    @MainActor
    func testCompanionChatModelExposesConfiguredPairingProfile() throws {
        let suiteName = "chat-surface-pairing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pairing = DaemonPairing(
            host: " Mac.Local ",
            port: 7443,
            apiVersion: "coven.daemon.v1",
            covenVersion: "0.7.0",
            pid: 42,
            startedAt: "now",
            pairedAt: Date()
        )
        let companion = CompanionModel(
            defaults: defaults,
            store: ChatSurfacePairingStore(stored: pairing)
        )
        let model = CompanionChatModel(companion: companion)

        XCTAssertEqual(model.configuredPairing, pairing)
        XCTAssertEqual(
            model.configuredFamiliarProfile,
            .companion(host: "mac.local", port: 7443)
        )

        companion.unpair()

        XCTAssertNil(model.configuredPairing)
        XCTAssertNil(model.configuredFamiliarProfile)
    }

    func testChatSurfacesUseConfiguredPairingForFamiliarProfile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in [
            "Sources/Support/ChatTypes.swift",
            "Sources/Views/ChatSettingsView.swift"
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains(
                    "companionPairing: companionModel.configuredPairing"
                ),
                path
            )
        }
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

    func testChatSurfaceStateSharesOneCompanionModelWithFamiliarSelection() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Support/ChatTypes.swift"
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

    func testChatRetrySuppliesLiveCompanionFamiliarSelection() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chat = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Views/ChatView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(chat.contains("await companionModel.retry {"))
        XCTAssertTrue(chat.contains("CompanionPromptRetrySelection("))
        XCTAssertTrue(chat.contains("familiarID: settings.familiarID"))
        XCTAssertTrue(
            chat.contains("familiar: familiarModel.selectedFamiliar")
        )
        XCTAssertTrue(
            chat.contains("profile: familiarModel.activeProfile")
        )
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
    func testDeletingLiveSessionIsRejectedUntilSessionIsReleased() async {
        let summary = makeSummary()
        let boundary = SessionBoundary()
        boundary.resumeSessions = [
            StubChatSession(sessionIdentifier: summary.sessionId)
        ]
        let model = ChatModel(performSessionOperation: boundary.perform)

        let resumed = await model.resume(
            summary,
            settings: ChatSettings(backend: .codex, model: "test")
        )
        XCTAssertTrue(resumed)

        do {
            try await model.deleteSession(summary)
            XCTFail("deleting the live session should be rejected")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Start a new chat before deleting the active session."
            )
        }
        XCTAssertTrue(model.hasActiveSession)
        XCTAssertEqual(model.activeSessionID, summary.sessionId)
    }

    @MainActor
    func testDeletingSessionIsRejectedWhileResumeIsInstallingIt() async {
        let summary = makeSummary()
        let boundary = SessionBoundary()
        boundary.suspendNextResume = true
        let model = ChatModel(performSessionOperation: boundary.perform)
        let resume = Task {
            await model.resume(
                summary,
                settings: ChatSettings(backend: .codex, model: "test")
            )
        }
        await fulfillment(of: [boundary.resumeRequested], timeout: 1)

        do {
            try await model.deleteSession(summary)
            XCTFail("deletion should not race an installing session")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Finish the current chat operation before deleting sessions."
            )
        }

        model.reset()
        boundary.finishResume(
            with: StubChatSession(sessionIdentifier: summary.sessionId)
        )
        let resumeSucceeded = await resume.value
        XCTAssertFalse(resumeSucceeded)
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
    func testRoutedResetRunnerQueuesDifferentBackendAfterActiveReset() async {
        let runner = RoutedResetRunner()
        let companionStarted = expectation(description: "companion reset started")
        let codexStarted = expectation(description: "Codex reset started")
        var companionContinuation: CheckedContinuation<Void, Never>?
        var codexContinuation: CheckedContinuation<Void, Never>?
        var resets: [ChatBackend] = []

        runner.launch(for: .companionClaude) {
            resets.append(.companionClaude)
            companionStarted.fulfill()
            await withCheckedContinuation { continuation in
                companionContinuation = continuation
            }
        }
        await fulfillment(of: [companionStarted], timeout: 1)

        runner.launch(for: .codex) {
            resets.append(.codex)
            codexStarted.fulfill()
            await withCheckedContinuation { continuation in
                codexContinuation = continuation
            }
        }
        companionContinuation?.resume()
        await fulfillment(of: [codexStarted], timeout: 1)
        codexContinuation?.resume()
        await runner.waitForCompletion()

        XCTAssertEqual(resets, [.companionClaude, .codex])
    }

    @MainActor
    func testRoutedResetRunnerCoalescesEquivalentActiveAndPendingResets() async {
        let runner = RoutedResetRunner()
        let companionStarted = expectation(description: "companion reset started")
        let codexStarted = expectation(description: "Codex reset started")
        var companionContinuation: CheckedContinuation<Void, Never>?
        var codexContinuation: CheckedContinuation<Void, Never>?
        var companionCount = 0
        var codexCount = 0

        runner.launch(for: .companionClaude) {
            companionCount += 1
            companionStarted.fulfill()
            await withCheckedContinuation { continuation in
                companionContinuation = continuation
            }
        }
        await fulfillment(of: [companionStarted], timeout: 1)

        runner.launch(for: .companionClaude) {
            XCTFail("an equivalent active reset must coalesce")
        }
        runner.launch(for: .codex) {
            codexCount += 1
            codexStarted.fulfill()
            await withCheckedContinuation { continuation in
                codexContinuation = continuation
            }
        }
        runner.launch(for: .codex) {
            XCTFail("an equivalent pending reset must coalesce")
        }

        companionContinuation?.resume()
        await fulfillment(of: [codexStarted], timeout: 1)
        codexContinuation?.resume()
        await runner.waitForCompletion()

        XCTAssertEqual(companionCount, 1)
        XCTAssertEqual(codexCount, 1)
    }

    @MainActor
    func testRoutedResetWaitsThroughQueuedReset() async {
        let runner = RoutedResetRunner()
        let companionStarted = expectation(description: "companion reset started")
        let codexStarted = expectation(description: "Codex reset started")
        let waitCompleted = expectation(description: "reset wait completed")
        var companionContinuation: CheckedContinuation<Void, Never>?
        var codexContinuation: CheckedContinuation<Void, Never>?
        var didCompleteWait = false

        runner.launch(for: .companionClaude) {
            companionStarted.fulfill()
            await withCheckedContinuation { continuation in
                companionContinuation = continuation
            }
        }
        await fulfillment(of: [companionStarted], timeout: 1)
        runner.launch(for: .codex) {
            codexStarted.fulfill()
            await withCheckedContinuation { continuation in
                codexContinuation = continuation
            }
        }

        let waiter = Task { @MainActor in
            await runner.waitForCompletion()
            didCompleteWait = true
            waitCompleted.fulfill()
        }
        companionContinuation?.resume()
        await fulfillment(of: [codexStarted], timeout: 1)
        await Task.yield()
        XCTAssertFalse(didCompleteWait)

        codexContinuation?.resume()
        await fulfillment(of: [waitCompleted], timeout: 1)
        await waiter.value
        XCTAssertTrue(didCompleteWait)
    }

    @MainActor
    func testRoutesWaitThroughQueuedRoutedReset() async {
        let coordinator = ChatRouteGenerationCoordinator()
        let companionStarted = expectation(description: "companion reset started")
        let codexStarted = expectation(description: "Codex reset started")
        var companionContinuation: CheckedContinuation<Void, Never>?
        var codexContinuation: CheckedContinuation<Void, Never>?
        var events: [String] = []

        coordinator.launchRoutedReset(for: .companionClaude) {
            events.append("companion-started")
            companionStarted.fulfill()
            await withCheckedContinuation { continuation in
                companionContinuation = continuation
            }
            events.append("companion-finished")
        }
        await fulfillment(of: [companionStarted], timeout: 1)
        coordinator.launchRoutedReset(for: .codex) {
            events.append("codex-started")
            codexStarted.fulfill()
            await withCheckedContinuation { continuation in
                codexContinuation = continuation
            }
            events.append("codex-finished")
        }

        let sessionToken = coordinator.begin()
        let sessionRoute = Task { @MainActor in
            await coordinator.runAfterRoutedReset(token: sessionToken) {
                events.append("session")
            }
        }
        companionContinuation?.resume()
        await fulfillment(of: [codexStarted], timeout: 1)
        await Task.yield()
        XCTAssertEqual(
            events,
            ["companion-started", "companion-finished", "codex-started"]
        )

        codexContinuation?.resume()
        await sessionRoute.value
        XCTAssertEqual(
            events,
            [
                "companion-started",
                "companion-finished",
                "codex-started",
                "codex-finished",
                "session"
            ]
        )
    }

    @MainActor
    func testRoutedResetRunnerPreservesActivePendingActiveOrdering() async {
        let runner = RoutedResetRunner()
        let firstCompanionStarted = expectation(description: "first companion reset started")
        let codexStarted = expectation(description: "Codex reset started")
        var firstCompanionContinuation: CheckedContinuation<Void, Never>?
        var codexContinuation: CheckedContinuation<Void, Never>?
        var resets: [String] = []

        runner.launch(for: .companionClaude) {
            resets.append("companion-1")
            firstCompanionStarted.fulfill()
            await withCheckedContinuation { continuation in
                firstCompanionContinuation = continuation
            }
        }
        await fulfillment(of: [firstCompanionStarted], timeout: 1)
        runner.launch(for: .codex) {
            resets.append("codex")
            codexStarted.fulfill()
            await withCheckedContinuation { continuation in
                codexContinuation = continuation
            }
        }
        runner.launch(for: .companionClaude) {
            XCTFail("the active companion reset already satisfies this request")
        }

        firstCompanionContinuation?.resume()
        await fulfillment(of: [codexStarted], timeout: 1)
        runner.launch(for: .companionClaude) {
            resets.append("companion-2")
        }
        codexContinuation?.resume()
        await runner.waitForCompletion()

        XCTAssertEqual(resets, ["companion-1", "codex", "companion-2"])
    }

    @MainActor
    func testRoutedResetRunnerOutlivesCancelledLaunchingTaskWithPendingReset() async {
        let runner = RoutedResetRunner()
        let companionStarted = expectation(description: "companion reset started")
        let codexStarted = expectation(description: "Codex reset started")
        var companionContinuation: CheckedContinuation<Void, Never>?
        var codexContinuation: CheckedContinuation<Void, Never>?
        var completionCount = 0

        let outerRouteTask = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertTrue(Task.isCancelled)
            runner.launch(for: .companionClaude) {
                XCTAssertFalse(Task.isCancelled)
                companionStarted.fulfill()
                await withCheckedContinuation { continuation in
                    companionContinuation = continuation
                }
                XCTAssertFalse(Task.isCancelled)
                completionCount += 1
            }
            runner.launch(for: .codex) {
                XCTAssertFalse(Task.isCancelled)
                codexStarted.fulfill()
                await withCheckedContinuation { continuation in
                    codexContinuation = continuation
                }
                XCTAssertFalse(Task.isCancelled)
                completionCount += 1
            }
        }
        await fulfillment(of: [companionStarted], timeout: 1)

        outerRouteTask.cancel()
        companionContinuation?.resume()
        await fulfillment(of: [codexStarted], timeout: 1)
        codexContinuation?.resume()
        await runner.waitForCompletion()
        await outerRouteTask.value

        XCTAssertEqual(completionCount, 2)
    }

    @MainActor
    func testRoutedResetQueueOutlivesOwnerDisappearance() async {
        var runner: RoutedResetRunner? = RoutedResetRunner()
        weak var retainedRunner = runner
        let companionStarted = expectation(description: "companion reset started")
        let codexStarted = expectation(description: "Codex reset started")
        var companionContinuation: CheckedContinuation<Void, Never>?
        var codexContinuation: CheckedContinuation<Void, Never>?

        runner?.launch(for: .companionClaude) {
            companionStarted.fulfill()
            await withCheckedContinuation { continuation in
                companionContinuation = continuation
            }
        }
        await fulfillment(of: [companionStarted], timeout: 1)
        runner?.launch(for: .codex) {
            codexStarted.fulfill()
            await withCheckedContinuation { continuation in
                codexContinuation = continuation
            }
        }

        runner = nil
        XCTAssertNotNil(retainedRunner)
        companionContinuation?.resume()
        await fulfillment(of: [codexStarted], timeout: 1)
        codexContinuation?.resume()
        for _ in 0..<100 where retainedRunner != nil {
            await Task.yield()
        }

        XCTAssertNil(retainedRunner)
    }

    @MainActor
    func testRoutesWaitForResetAndOnlyCurrentRouteProceedsOnce() async {
        let coordinator = ChatRouteGenerationCoordinator()
        let resetStarted = expectation(description: "routed reset started")
        var resetContinuation: CheckedContinuation<Void, Never>?
        var events: [String] = []
        coordinator.launchRoutedReset(for: .companionClaude) {
            events.append("reset-started")
            resetStarted.fulfill()
            await withCheckedContinuation { continuation in
                resetContinuation = continuation
            }
            events.append("reset-finished")
        }
        await fulfillment(of: [resetStarted], timeout: 1)

        let promptToken = coordinator.begin()
        let promptRoute = Task { @MainActor in
            await coordinator.runAfterRoutedReset(token: promptToken) {
                events.append("prompt")
            }
        }
        let sessionToken = coordinator.begin()
        let sessionRoute = Task { @MainActor in
            await coordinator.runAfterRoutedReset(token: sessionToken) {
                events.append("session")
            }
        }
        await Task.yield()
        XCTAssertEqual(events, ["reset-started"])

        resetContinuation?.resume()
        await promptRoute.value
        await sessionRoute.value

        XCTAssertEqual(
            events,
            ["reset-started", "reset-finished", "session"]
        )
    }

    @MainActor
    func testSessionRouteIsRejectedUntilPendingCleanupClears() async {
        let coordinator = ChatRouteGenerationCoordinator()
        var hasPendingCleanup = true
        var resumeCount = 0
        let blockedToken = coordinator.begin()

        await coordinator.runAfterRoutedReset(
            token: blockedToken,
            canProceed: { !hasPendingCleanup },
            operation: { resumeCount += 1 }
        )

        XCTAssertEqual(resumeCount, 0)
        XCTAssertFalse(coordinator.isCurrent(blockedToken))

        hasPendingCleanup = false
        let readyToken = coordinator.begin()
        await coordinator.runAfterRoutedReset(
            token: readyToken,
            canProceed: { !hasPendingCleanup },
            operation: { resumeCount += 1 }
        )

        XCTAssertEqual(resumeCount, 1)
    }

    @MainActor
    func testRoutedCodexResetCoalescesAndRemainsGenerationSafe() async {
        let boundary = SessionBoundary()
        boundary.suspendNextStart = true
        let model = ChatModel(performSessionOperation: boundary.perform)
        let settings = ChatSettings(backend: .codex, model: "test")
        let pendingSend = Task {
            await model.send(prompt: "stale", settings: settings)
        }
        await fulfillment(of: [boundary.startRequested], timeout: 1)

        let coordinator = ChatRouteGenerationCoordinator()
        var resetCount = 0
        coordinator.launchRoutedReset(for: .codex) {
            resetCount += 1
            model.reset()
        }
        coordinator.launchRoutedReset(for: .codex) {
            resetCount += 1
            model.reset()
        }
        await coordinator.waitForRoutedReset()

        let lateSession = TrackingChatSession()
        boundary.finishStart(with: lateSession)
        await pendingSend.value

        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(lateSession.stopCallCount, 1)
        XCTAssertFalse(model.hasActiveSession)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor
    func testRoutedCompanionResetSurvivesFlagCancellationAndViewDisappearance() async throws {
        let fixture = try await makeHostedRoutedResetFixture()
        defer { fixture.cleanup() }
        await finishInitialHostedAvailability(fixture)
        let gateCallsBeforeReset = fixture.remoteClient.gateCallCount

        fixture.remoteClient.suspendsKill = true
        fixture.remoteClient.killChecksCancellation = true
        fixture.router.startFreshChat()
        fixture.router.openChat(prompt: "after cleanup")
        for _ in 0..<100
                where fixture.remoteClient.gateCallCount == gateCallsBeforeReset {
            await Task.yield()
        }
        XCTAssertGreaterThan(
            fixture.remoteClient.gateCallCount,
            gateCallsBeforeReset
        )

        fixture.window.isHidden = true
        fixture.window.rootViewController = nil
        fixture.remoteClient.resumeNextGate(with: .ready(fixture.pairing))
        await fulfillment(
            of: [fixture.remoteClient.killRequested],
            timeout: 1
        )

        XCTAssertTrue(fixture.companionChat.hasPendingCleanup)
        XCTAssertTrue(fixture.companionChat.isBusy)
        XCTAssertEqual(fixture.remoteClient.launchedPrompts, ["remote"])
        fixture.remoteClient.suspendsGate = false
        fixture.remoteClient.resumeKill()
        for _ in 0..<100 where fixture.remoteClient.launchedPrompts.count == 1 {
            await Task.yield()
        }
        completeTurn(on: fixture.companionChat)

        XCTAssertEqual(fixture.remoteClient.killedSessionIDs, ["session-1"])
        XCTAssertEqual(
            fixture.remoteClient.launchedPrompts,
            ["remote", "after cleanup"]
        )
        XCTAssertFalse(fixture.companionChat.hasPendingCleanup)
        XCTAssertFalse(fixture.companionChat.isBusy)
        XCTAssertFalse(fixture.companionChat.canRetry)
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
    private func makeHostedRoutedResetFixture() async throws
        -> HostedRoutedResetFixture {
        let pairing = pairedDaemon()
        let remoteClient = FakeCompanionSessionClient(gate: .ready(pairing))
        let companion = CompanionModel(
            store: ChatSurfacePairingStore(stored: pairing)
        )
        let companionChat = CompanionChatModel(
            companion: companion,
            client: remoteClient
        )
        await companionChat.send(prompt: "remote", projectRoot: "/srv/repo")
        let suiteName = "routed-reset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let chatState = makeRoutedResetChatState(
            companion: companion,
            companionChat: companionChat,
            defaults: defaults
        )
        let router = AppRouter.shared
        let previousTab = router.selectedTab
        _ = router.consumePrompt()
        _ = router.consumeSessionID()
        _ = router.consumeReset()
        router.selectedTab = .chat
        remoteClient.suspendsGate = true
        let host = UIHostingController(
            rootView: ChatView(client: EngineClient(), chatState: chatState)
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return HostedRoutedResetFixture(
            suiteName: suiteName,
            defaults: defaults,
            pairing: pairing,
            remoteClient: remoteClient,
            companionChat: companionChat,
            router: router,
            previousTab: previousTab,
            window: window
        )
    }

    @MainActor
    private func makeRoutedResetChatState(
        companion: CompanionModel,
        companionChat: CompanionChatModel,
        defaults: UserDefaults
    ) -> ChatSurfaceState {
        let familiarModel = FamiliarSelectionModel(
            client: NoopFamiliarRosterClient(),
            store: FamiliarSelectionStore(defaults: defaults)
        )
        return ChatSurfaceState(
            model: ChatModel(),
            companion: companion,
            companionModel: companionChat,
            familiarModel: familiarModel,
            routeCoordinator: ChatRouteGenerationCoordinator(),
            settings: ChatSettings(
                backend: .companionClaude,
                daemonProjectRoot: "/srv/repo"
            )
        )
    }

    @MainActor
    private func finishInitialHostedAvailability(
        _ fixture: HostedRoutedResetFixture
    ) async {
        await fulfillment(
            of: [fixture.remoteClient.gateRequested],
            timeout: 1
        )
        fixture.remoteClient.resumeNextGate(with: .ready(fixture.pairing))
        for _ in 0..<100
                where fixture.companionChat.availability == .checking {
            await Task.yield()
        }
        XCTAssertEqual(
            fixture.companionChat.availability,
            .ready(fixture.pairing)
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

    @MainActor
    private func makeAccountTransitionFamiliarFixture() throws
        -> AccountTransitionFamiliarFixture {
        let suiteName = "account-transition-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = FamiliarSelectionStore(defaults: defaults)
        let profileA = FamiliarProfileKey.codex(profileID: "profile-a")
        let profileB = FamiliarProfileKey.codex(profileID: "profile-b")
        let sage = familiarIdentity(id: "sage", name: "Sage")
        let forge = familiarIdentity(id: "forge", name: "Forge")
        try store.save(sage, for: profileA)
        try store.save(forge, for: profileB)
        let model = FamiliarSelectionModel(
            client: NoopFamiliarRosterClient(),
            store: store
        )
        model.activate(profileA)
        return AccountTransitionFamiliarFixture(
            suiteName: suiteName,
            defaults: defaults,
            store: store,
            model: model,
            profileA: profileA,
            profileB: profileB,
            sage: sage,
            forge: forge
        )
    }

    @MainActor
    private func makeHostedRootTransitionFixture() throws
        -> HostedRootTransitionFixture {
        let familiar = try makeAccountTransitionFamiliarFixture()
        let boundary = SessionBoundary()
        boundary.suspendNextStart = true
        let chatModel = ChatModel(performSessionOperation: boundary.perform)
        let routes = ChatRouteGenerationCoordinator()
        let staleRoute = routes.begin()
        let companion = CompanionModel(
            store: ChatSurfacePairingStore(stored: nil)
        )
        let chatState = ChatSurfaceState(
            model: chatModel,
            companion: companion,
            companionModel: CompanionChatModel(companion: companion),
            familiarModel: familiar.model,
            routeCoordinator: routes,
            settings: ChatSettings(
                backend: .codex,
                model: "test",
                familiarID: familiar.sage.id
            )
        )
        let client = EngineClient()
        client.codexAccount = CodexAccount(
            profileId: "profile-a",
            email: "a@example.com",
            accountId: nil
        )
        let previousTab = AppRouter.shared.selectedTab
        AppRouter.shared.selectedTab = .chat
        let host = UIHostingController(
            rootView: RootView(client: client, chatState: chatState)
                .environment(\.horizontalSizeClass, .regular)
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return HostedRootTransitionFixture(
            familiar: familiar,
            boundary: boundary,
            chatModel: chatModel,
            routes: routes,
            staleRoute: staleRoute,
            chatState: chatState,
            client: client,
            previousTab: previousTab,
            window: window
        )
    }

    @MainActor
    private func makeWindowAccountFixture(
        suspendsOnDeviceStart: Bool
    ) async throws -> WindowAccountFixture {
        let suiteName = "window-account-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let boundary = SessionBoundary()
        boundary.suspendNextStart = suspendsOnDeviceStart
        let model = ChatModel(
            defaults: defaults,
            performSessionOperation: boundary.perform
        )
        let routes = ChatRouteGenerationCoordinator()
        let companion = CompanionModel(
            store: ChatSurfacePairingStore(stored: nil)
        )
        let companionClient = FakeCompanionSessionClient(
            gate: .ready(pairedDaemon())
        )
        let companionModel = CompanionChatModel(client: companionClient)
        await companionModel.send(prompt: "remote", projectRoot: "/srv/repo")
        let familiarModel = FamiliarSelectionModel(
            client: NoopFamiliarRosterClient(),
            store: FamiliarSelectionStore(defaults: defaults)
        )
        let chatState = ChatSurfaceState(
            model: model,
            companion: companion,
            companionModel: companionModel,
            familiarModel: familiarModel,
            routeCoordinator: routes,
            settings: ChatSettings(backend: .codex, model: "test")
        )
        return WindowAccountFixture(
            suiteName: suiteName,
            defaults: defaults,
            boundary: boundary,
            model: model,
            routes: routes,
            companionClient: companionClient,
            companionModel: companionModel,
            chatState: chatState
        )
    }

    @MainActor
    private func assertAccountTransitionReset(
        first: WindowAccountFixture,
        second: WindowAccountFixture,
        transition: WindowTransitionResult
    ) {
        XCTAssertTrue(
            transition.firstWindow.sectionFactory.client === transition.client
        )
        XCTAssertTrue(
            transition.secondWindow.sectionFactory.client === transition.client
        )
        XCTAssertEqual(transition.firstSession.stopCallCount, 1)
        XCTAssertEqual(transition.lateSecondSession.stopCallCount, 1)
        XCTAssertFalse(first.routes.isCurrent(transition.firstRoute))
        XCTAssertFalse(second.routes.isCurrent(transition.secondRoute))
        XCTAssertFalse(first.model.hasActiveSession)
        XCTAssertFalse(second.model.hasActiveSession)
        XCTAssertTrue(first.model.items.isEmpty)
        XCTAssertTrue(second.model.items.isEmpty)
        XCTAssertTrue(first.companionModel.hasActiveSession)
        XCTAssertTrue(second.companionModel.hasActiveSession)
        XCTAssertEqual(first.companionModel.items.map(\.text), ["remote"])
        XCTAssertEqual(second.companionModel.items.map(\.text), ["remote"])
        XCTAssertTrue(first.companionClient.killedSessionIDs.isEmpty)
        XCTAssertTrue(second.companionClient.killedSessionIDs.isEmpty)
    }

    @MainActor
    private func performSharedAccountTransition(
        first: WindowAccountFixture,
        second: WindowAccountFixture
    ) async -> WindowTransitionResult {
        let firstSession = TrackingChatSession()
        first.boundary.startSessions = [firstSession]
        await first.model.send(
            prompt: "account A active",
            settings: first.chatState.settings
        )
        let pendingSend = Task {
            await second.model.send(
                prompt: "account A in flight",
                settings: second.chatState.settings
            )
        }
        await fulfillment(of: [second.boundary.startRequested], timeout: 1)
        let lateSecondSession = TrackingChatSession()
        let client = EngineClient(engine: SuspendedAuthEngine())
        client.codexAccount = CodexAccount(
            profileId: "profile-a",
            email: "a@example.com",
            accountId: nil
        )
        let app = CovenPocketApp(
            dependencies: CovenPocketAppDependencies(engineClient: client)
        )
        let firstWindow = app.rootWindowFactory.makeWindowState(
            chatState: first.chatState
        )
        let secondWindow = app.rootWindowFactory.makeWindowState(
            chatState: second.chatState
        )
        let firstRoute = first.routes.begin()
        let secondRoute = second.routes.begin()

        client.codexAccount = CodexAccount(
            profileId: "profile-b",
            email: "b@example.com",
            accountId: nil
        )
        second.boundary.finishStart(with: lateSecondSession)
        await pendingSend.value
        return WindowTransitionResult(
            firstWindow: firstWindow,
            secondWindow: secondWindow,
            client: client,
            firstSession: firstSession,
            lateSecondSession: lateSecondSession,
            firstRoute: firstRoute,
            secondRoute: secondRoute
        )
    }

    @MainActor
    private func assertSameProfilePreservesWindows(
        first: WindowAccountFixture,
        second: WindowAccountFixture,
        client: EngineClient
    ) async {
        let firstSession = TrackingChatSession()
        let secondSession = TrackingChatSession()
        first.boundary.startSessions = [firstSession]
        second.boundary.startSessions = [secondSession]
        await first.model.send(
            prompt: "account B first",
            settings: first.chatState.settings
        )
        await second.model.send(
            prompt: "account B second",
            settings: second.chatState.settings
        )

        client.codexAccount = CodexAccount(
            profileId: "profile-b",
            email: "updated@example.com",
            accountId: "updated"
        )

        XCTAssertTrue(first.model.hasActiveSession)
        XCTAssertTrue(second.model.hasActiveSession)
        XCTAssertEqual(firstSession.stopCallCount, 0)
        XCTAssertEqual(secondSession.stopCallCount, 0)
        XCTAssertEqual(first.companionModel.items.map(\.text), ["remote"])
        XCTAssertEqual(second.companionModel.items.map(\.text), ["remote"])
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

    private func pocketModel(id: String) -> PocketModel {
        PocketModel(
            id: id,
            providerId: "codex",
            name: id,
            contextWindow: 128_000,
            maxOutputTokens: 16_000
        )
    }

    func testSummaryDisplayTitleFallsBack() {
        XCTAssertEqual(makeSummary(title: "Fix the bug").displayTitle, "Fix the bug")
        XCTAssertEqual(makeSummary(title: "").displayTitle, "Untitled session")
        let summary = makeSummary()
        XCTAssertEqual(summary.id, summary.sessionId)
    }
}
