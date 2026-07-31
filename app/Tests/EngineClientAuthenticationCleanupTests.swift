import XCTest
@testable import CovenPocket

final class EngineClientAuthenticationCleanupTests: XCTestCase {
    @MainActor
    func testInvalidatedSuccessfulLoginRetainsFailedCleanupForRetry() async {
        let engine = ControllableEngineClientEngine()
        let store = TestAuthenticationCleanupStore()
        let client = EngineClient(
            engine: engine,
            authenticationCleanupStore: store
        )
        let login = Task { await client.codexLogin() }
        await waitUntil { engine.pendingLoginCount == 1 }

        client.codexLogout()
        engine.failNextLogouts(1)
        engine.finishLogin(at: 0, with: .success(account("profile-a")))
        await login.value

        XCTAssertNil(client.codexAccount)
        XCTAssertTrue(client.codexModels.isEmpty)
        XCTAssertNil(client.authURL)
        XCTAssertTrue(client.authenticationCleanupRequired)
        XCTAssertTrue(store.cleanupRequired)
        XCTAssertEqual(engine.logoutCallCount, 1)
        XCTAssertTrue(
            client.authenticationCleanupError?.contains(
                "logout cleanup failed"
            ) == true
        )
        XCTAssertTrue(
            client.authenticationCleanupError?.contains(
                "Finish sign out"
            ) == true
        )
    }

    @MainActor
    func testIndependentCleanupRetryClearsDurableAndPresentedAuthState() {
        let engine = ControllableEngineClientEngine(account: account("profile-a"))
        engine.failNextLogouts(1)
        let store = TestAuthenticationCleanupStore()
        let client = EngineClient(
            engine: engine,
            authenticationCleanupStore: store
        )
        client.codexModels = [model("stale-model")]
        client.authURL = URL(string: "https://example.com/stale")
        client.codexLogout()

        client.retryAuthenticationCleanup()

        XCTAssertFalse(client.authenticationCleanupRequired)
        XCTAssertFalse(store.cleanupRequired)
        XCTAssertNil(client.authenticationCleanupError)
        XCTAssertNil(client.codexAccount)
        XCTAssertTrue(client.codexModels.isEmpty)
        XCTAssertNil(client.authURL)
        XCTAssertNil(engine.codexAccount())
    }

    @MainActor
    func testRepeatedCleanupRetryFailuresRemainVisibleAndUpdateError() {
        let engine = ControllableEngineClientEngine(account: account("profile-a"))
        engine.failLogouts(
            with: [.logoutCleanup, .logoutRetry, .logoutStillPending]
        )
        let store = TestAuthenticationCleanupStore()
        let client = EngineClient(
            engine: engine,
            authenticationCleanupStore: store
        )
        client.codexLogout()
        let initialError = client.authenticationCleanupError

        client.retryAuthenticationCleanup()
        let retryError = client.authenticationCleanupError
        client.retryAuthenticationCleanup()

        XCTAssertNotEqual(initialError, retryError)
        XCTAssertNotEqual(retryError, client.authenticationCleanupError)
        XCTAssertTrue(client.authenticationCleanupRequired)
        XCTAssertTrue(store.cleanupRequired)
        XCTAssertNil(client.codexAccount)
        XCTAssertEqual(engine.logoutCallCount, 3)
        XCTAssertFalse(store.savedValues.contains(false))
    }

    @MainActor
    func testStartupCleanupSucceedsBeforeReadingStaleAccount() {
        let engine = ControllableEngineClientEngine(account: account("profile-a"))
        let store = TestAuthenticationCleanupStore(cleanupRequired: true)

        let client = EngineClient(
            engine: engine,
            authenticationCleanupStore: store
        )

        XCTAssertEqual(engine.authenticationEvents, ["logout"])
        XCTAssertEqual(engine.codexAccountCallCount, 0)
        XCTAssertNil(client.codexAccount)
        XCTAssertFalse(client.authenticationCleanupRequired)
        XCTAssertFalse(store.cleanupRequired)
        XCTAssertNil(client.authenticationCleanupError)
    }

    @MainActor
    func testStartupCleanupFailureHidesStaleAccountAndRemainsRetryable() {
        let engine = ControllableEngineClientEngine(account: account("profile-a"))
        engine.failNextLogouts(1)
        let store = TestAuthenticationCleanupStore(cleanupRequired: true)

        let client = EngineClient(
            engine: engine,
            authenticationCleanupStore: store
        )

        XCTAssertEqual(engine.authenticationEvents, ["logout"])
        XCTAssertEqual(engine.codexAccountCallCount, 0)
        XCTAssertNil(client.codexAccount)
        XCTAssertTrue(client.authenticationCleanupRequired)
        XCTAssertTrue(store.cleanupRequired)
        XCTAssertNotNil(client.authenticationCleanupError)
        XCTAssertFalse(store.savedValues.contains(false))
    }

    @MainActor
    func testCleanupRetryDoesNotRaceActiveAuthentication() async {
        let engine = ControllableEngineClientEngine()
        let store = TestAuthenticationCleanupStore()
        let client = EngineClient(
            engine: engine,
            authenticationCleanupStore: store
        )
        let login = Task { await client.codexLogin() }
        await waitUntil { engine.pendingLoginCount == 1 }

        client.codexLogout()
        let deferredError = client.authenticationCleanupError
        client.retryAuthenticationCleanup()

        XCTAssertEqual(engine.logoutCallCount, 0)
        XCTAssertTrue(client.authenticationCleanupRequired)
        XCTAssertTrue(store.cleanupRequired)
        XCTAssertEqual(client.authenticationCleanupError, deferredError)

        engine.finishLogin(
            at: 0,
            with: .failure(EngineClientTestError.staleStream)
        )
        await login.value
        client.retryAuthenticationCleanup()

        XCTAssertEqual(engine.logoutCallCount, 1)
        XCTAssertFalse(client.authenticationCleanupRequired)
        XCTAssertFalse(store.cleanupRequired)
    }

    @MainActor
    func testLogoutDuringPostLoginModelLoadAttemptsCleanupImmediately() async {
        let engine = ControllableEngineClientEngine()
        engine.suspendNextCodexModelLoads(1)
        let store = TestAuthenticationCleanupStore()
        let client = EngineClient(
            engine: engine,
            authenticationCleanupStore: store
        )
        let login = Task { await client.codexLogin() }
        await waitUntil { engine.pendingLoginCount == 1 }
        engine.finishLogin(at: 0, with: .success(account("profile-a")))
        await waitUntil { engine.pendingCodexModelLoadCount == 1 }

        client.codexLogout()

        XCTAssertEqual(engine.logoutCallCount, 1)
        XCTAssertFalse(client.authenticationCleanupRequired)
        XCTAssertFalse(store.cleanupRequired)
        XCTAssertNil(client.codexAccount)
        engine.finishCodexModelLoad(
            at: 0,
            with: .success([model("stale-model")])
        )
        await login.value

        XCTAssertTrue(client.codexModels.isEmpty)
        XCTAssertNil(client.codexAccount)
        XCTAssertFalse(client.isAuthenticating)
    }

    @MainActor
    func testExplicitLogoutFailureUsesDurableCleanupPath() {
        let engine = ControllableEngineClientEngine(account: account("profile-a"))
        engine.failNextLogouts(1)
        let store = TestAuthenticationCleanupStore()
        let client = EngineClient(
            engine: engine,
            authenticationCleanupStore: store
        )
        client.codexModels = [model("stale-model")]
        client.authURL = URL(string: "https://example.com/stale")

        client.codexLogout()

        XCTAssertNil(client.codexAccount)
        XCTAssertTrue(client.codexModels.isEmpty)
        XCTAssertNil(client.authURL)
        XCTAssertTrue(client.authenticationCleanupRequired)
        XCTAssertTrue(store.cleanupRequired)
        XCTAssertNotNil(client.authenticationCleanupError)
    }

    @MainActor
    func testCleanLoginWorksAfterCleanupRetrySucceeds() async {
        let engine = ControllableEngineClientEngine(account: account("profile-a"))
        engine.failNextLogouts(1)
        let store = TestAuthenticationCleanupStore()
        let client = EngineClient(
            engine: engine,
            authenticationCleanupStore: store
        )
        client.codexLogout()
        client.retryAuthenticationCleanup()

        let login = Task { await client.codexLogin() }
        await waitUntil { engine.pendingLoginCount == 1 }
        engine.finishLogin(at: 0, with: .success(account("profile-b")))
        await login.value

        XCTAssertEqual(client.codexAccount?.profileId, "profile-b")
        XCTAssertFalse(client.authenticationCleanupRequired)
        XCTAssertFalse(store.cleanupRequired)
        XCTAssertNil(client.authenticationCleanupError)
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }

    private func account(_ profileID: String) -> CodexAccount {
        CodexAccount(
            profileId: profileID,
            email: "\(profileID)@example.com",
            accountId: nil
        )
    }

    private func model(_ id: String) -> PocketModel {
        PocketModel(
            id: id,
            providerId: "codex",
            name: id,
            contextWindow: 1,
            maxOutputTokens: 1
        )
    }
}
