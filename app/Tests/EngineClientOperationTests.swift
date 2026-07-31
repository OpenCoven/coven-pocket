import XCTest
@testable import CovenPocket

// swiftlint:disable type_body_length
final class EngineClientOperationTests: XCTestCase {
    @MainActor
    func testOverlappingSendDoesNotStartOrClearFirstStream() async {
        let engine = ControllableEngineClientEngine()
        let client = EngineClient(engine: engine)
        let first = send(client, provider: .anthropic, prompt: "first")
        await waitUntil { engine.pendingStreamCount == 1 }
        engine.emitText("first", stream: 0)
        engine.emitThinking("thought", stream: 0)
        await waitUntil {
            client.transcript == "first" && client.thinking == "thought"
        }

        let secondAttempted = expectation(description: "second send attempted")
        let second = Task { @MainActor in
            secondAttempted.fulfill()
            await client.send(
                provider: .anthropic,
                apiKey: "key",
                model: "model",
                prompt: "second",
                effort: nil
            )
        }
        await fulfillment(of: [secondAttempted], timeout: 1)
        await drainMainActor()

        XCTAssertEqual(engine.streamCallCount, 1)
        XCTAssertEqual(client.transcript, "first")
        XCTAssertEqual(client.thinking, "thought")
        XCTAssertTrue(client.isStreaming)

        engine.emitText("-tail", stream: 0)
        engine.finishAllStreams()
        await first.value
        await second.value
        await drainMainActor()

        XCTAssertEqual(client.transcript, "first-tail")
        XCTAssertEqual(client.thinking, "thought")
        XCTAssertNil(client.errorMessage)
        XCTAssertFalse(client.isStreaming)
    }

    @MainActor
    func testCodexAccountTransitionQuarantinesOldStreamAndAllowsNewSend() async {
        let engine = ControllableEngineClientEngine(account: account("profile-a"))
        let client = EngineClient(engine: engine)
        let oldSend = send(client, provider: .codex, prompt: "old")
        await waitUntil { engine.pendingStreamCount == 1 }
        engine.emitText("account-a", stream: 0)
        engine.emitThinking("a-thought", stream: 0)
        await waitUntil {
            client.transcript == "account-a"
                && client.thinking == "a-thought"
        }

        client.codexAccount = account("profile-b")

        XCTAssertEqual(client.transcript, "")
        XCTAssertEqual(client.thinking, "")
        XCTAssertFalse(client.isStreaming)

        let newSend = send(client, provider: .codex, prompt: "new")
        await waitUntil { engine.pendingStreamCount == 2 }
        engine.emitText("-late", stream: 0)
        engine.emitThinking("-late", stream: 0)
        engine.emitError("late callback error", stream: 0)
        engine.finishStream(
            at: 0,
            with: .failure(EngineClientTestError.staleStream)
        )
        await oldSend.value
        await drainMainActor()

        XCTAssertEqual(client.transcript, "")
        XCTAssertEqual(client.thinking, "")
        XCTAssertNil(client.errorMessage)
        XCTAssertTrue(client.isStreaming)

        engine.emitText("account-b", stream: 1)
        engine.emitThinking("b-thought", stream: 1)
        engine.finishStream(at: 1)
        await newSend.value
        await drainMainActor()

        XCTAssertEqual(client.transcript, "account-b")
        XCTAssertEqual(client.thinking, "b-thought")
        XCTAssertNil(client.errorMessage)
        XCTAssertFalse(client.isStreaming)
    }

    @MainActor
    func testNewSendSupersedesQueuedCallbacksFromCompletedStream() async {
        let engine = ControllableEngineClientEngine()
        engine.completeNextStreamsImmediately(2)
        let client = EngineClient(engine: engine)
        await client.send(
            provider: .anthropic,
            apiKey: "key",
            model: "model",
            prompt: "old",
            effort: nil
        )
        engine.emitText("stale", stream: 0)
        engine.emitThinking("stale-thought", stream: 0)
        engine.emitError("stale error", stream: 0)

        await client.send(
            provider: .anthropic,
            apiKey: "key",
            model: "model",
            prompt: "new",
            effort: nil
        )
        engine.emitText("fresh", stream: 1)
        engine.emitThinking("fresh-thought", stream: 1)
        await drainMainActor()

        XCTAssertEqual(client.transcript, "fresh")
        XCTAssertEqual(client.thinking, "fresh-thought")
        XCTAssertNil(client.errorMessage)
    }

    @MainActor
    func testCompletedCurrentStreamDrainsQueuedCallbacks() async {
        let engine = ControllableEngineClientEngine()
        engine.completeNextStreamsImmediately(1)
        let client = EngineClient(engine: engine)
        await client.send(
            provider: .anthropic,
            apiKey: "key",
            model: "model",
            prompt: "current",
            effort: nil
        )
        XCTAssertFalse(client.isStreaming)

        engine.emitText("tail", stream: 0)
        engine.emitThinking("tail-thought", stream: 0)
        engine.emitError("queued error", stream: 0)
        await drainMainActor()

        XCTAssertEqual(client.transcript, "tail")
        XCTAssertEqual(client.thinking, "tail-thought")
        XCTAssertEqual(client.errorMessage, "queued error")
    }

    @MainActor
    func testCompletedCodexStreamCannotReviveAfterAccountCyclesBack() async {
        let engine = ControllableEngineClientEngine(account: account("profile-a"))
        engine.completeNextStreamsImmediately(1)
        let client = EngineClient(engine: engine)
        await client.send(
            provider: .codex,
            apiKey: "",
            model: "model",
            prompt: "current",
            effort: nil
        )
        engine.emitText("account-a", stream: 0)
        await waitUntil { client.transcript == "account-a" }

        client.codexAccount = account("profile-b")
        engine.emitText("-late", stream: 0)
        client.codexAccount = account("profile-a")
        await drainMainActor()

        XCTAssertEqual(client.transcript, "")
        XCTAssertEqual(client.thinking, "")
        XCTAssertNil(client.errorMessage)
    }

    @MainActor
    func testAnthropicStreamSurvivesCodexAccountTransition() async {
        let engine = ControllableEngineClientEngine(account: account("profile-a"))
        let client = EngineClient(engine: engine)
        let stream = send(client, provider: .anthropic, prompt: "anthropic")
        await waitUntil { engine.pendingStreamCount == 1 }
        engine.emitText("before-", stream: 0)
        await waitUntil { client.transcript == "before-" }

        client.codexAccount = account("profile-b")

        XCTAssertTrue(client.isStreaming)
        XCTAssertEqual(client.transcript, "before-")

        engine.emitText("after", stream: 0)
        engine.finishStream(at: 0)
        await stream.value
        await drainMainActor()

        XCTAssertEqual(client.transcript, "before-after")
        XCTAssertNil(client.errorMessage)
        XCTAssertFalse(client.isStreaming)
    }

    @MainActor
    func testSignedOutCodexStreamInvalidatesWhenAccountAppears() async {
        let engine = ControllableEngineClientEngine()
        let client = EngineClient(engine: engine)
        let stream = send(client, provider: .codex, prompt: "signed out")
        await waitUntil { engine.pendingStreamCount == 1 }
        engine.emitText("anonymous", stream: 0)
        await waitUntil { client.transcript == "anonymous" }

        client.codexAccount = account("profile-b")
        engine.emitText("-late", stream: 0)
        engine.finishStream(at: 0)
        await stream.value
        await drainMainActor()

        XCTAssertEqual(client.transcript, "")
        XCTAssertEqual(client.thinking, "")
        XCTAssertFalse(client.isStreaming)
    }

    @MainActor
    func testLogoutInvalidatesSuspendedLoginCallbacksAndCompletion() async {
        let engine = ControllableEngineClientEngine()
        let client = EngineClient(engine: engine)
        let login = Task { await client.codexLogin() }
        await waitUntil { engine.pendingLoginCount == 1 }
        engine.emitAuthURL("https://example.com/old", login: 0)
        await waitUntil {
            client.authURL == URL(string: "https://example.com/old")
        }

        client.codexLogout()

        XCTAssertFalse(client.isAuthenticating)
        XCTAssertNil(client.authURL)
        XCTAssertNil(client.codexAccount)

        engine.emitAuthURL("https://example.com/late", login: 0)
        engine.finishLogin(at: 0, with: .success(account("profile-a")))
        await login.value
        await drainMainActor()

        XCTAssertNil(client.authURL)
        XCTAssertNil(client.codexAccount)
        XCTAssertTrue(client.codexModels.isEmpty)
        XCTAssertEqual(engine.codexModelLoadCallCount, 0)
        XCTAssertFalse(client.isAuthenticating)
    }

    @MainActor
    func testLoginAfterLogoutSupersedesPreviousLogin() async {
        let engine = ControllableEngineClientEngine()
        let client = EngineClient(engine: engine)
        let oldLogin = Task { await client.codexLogin() }
        await waitUntil { engine.pendingLoginCount == 1 }
        client.codexLogout()
        engine.failNextLogouts(1)

        let newLogin = Task { await client.codexLogin() }
        await drainMainActor()
        XCTAssertEqual(engine.loginCallCount, 1)
        XCTAssertEqual(engine.pendingLoginCount, 1)

        engine.emitAuthURL("https://example.com/old", login: 0)
        engine.finishLogin(at: 0, with: .success(account("profile-a")))
        await oldLogin.value
        await waitUntil {
            engine.loginCallCount == 2 && engine.pendingLoginCount == 1
        }
        engine.emitAuthURL("https://example.com/new", login: 1)
        await waitUntil {
            client.authURL == URL(string: "https://example.com/new")
        }
        engine.finishLogin(at: 1, with: .success(account("profile-b")))
        await newLogin.value
        await drainMainActor()

        XCTAssertEqual(client.codexAccount?.profileId, "profile-b")
        XCTAssertEqual(engine.codexAccount()?.profileId, "profile-b")
        XCTAssertEqual(engine.logoutCallCount, 2)
        XCTAssertNil(client.authURL)
        XCTAssertFalse(client.isAuthenticating)
    }

    @MainActor
    func testOlderSameProfileModelFailureCannotOverwriteNewerSuccess() async {
        let engine = ControllableEngineClientEngine(account: account("profile-a"))
        engine.suspendNextCodexModelLoads(2)
        let client = EngineClient(engine: engine)
        let older = Task { await client.loadCodexModels() }
        await waitUntil { engine.pendingCodexModelLoadCount == 1 }
        let newer = Task { await client.loadCodexModels() }
        await waitUntil { engine.pendingCodexModelLoadCount == 2 }
        let currentModels = [model("current")]

        engine.finishCodexModelLoad(at: 1, with: .success(currentModels))
        await newer.value
        engine.finishCodexModelLoad(
            at: 0,
            with: .failure(EngineClientTestError.staleModelLoad)
        )
        await older.value

        XCTAssertEqual(client.codexModels, currentModels)
        XCTAssertNil(client.errorMessage)
    }

    @MainActor
    private func send(
        _ client: EngineClient,
        provider: PocketProvider,
        prompt: String
    ) -> Task<Void, Never> {
        Task {
            await client.send(
                provider: provider,
                apiKey: "key",
                model: "model",
                prompt: prompt,
                effort: nil
            )
        }
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

    @MainActor
    private func drainMainActor() async {
        for _ in 0..<20 {
            await Task.yield()
        }
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
// swiftlint:enable type_body_length
