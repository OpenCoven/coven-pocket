import XCTest
@testable import CovenPocket

private final class NoopSessionListChatDelegate: ChatDelegate, @unchecked Sendable {
    func onText(text: String) {}
    func onThinking(text: String) {}
    func onToolStart(toolId: String, toolName: String, inputJson: String) {}
    func onToolEnd(
        toolId: String,
        toolName: String,
        result: String,
        isError: Bool
    ) {}
    func onStatus(message: String) {}
    func onPermissionRequest(
        request: ChatPermissionRequest,
        responder: ChatPermissionResponder
    ) {
        responder.respond(decision: .deny)
    }
    func onDone(stopReason: String) {}
    func onError(message: String) {}
}

@MainActor
final class SessionListIntegrationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let storage: URL
        let engine: PocketEngine
        let session: ChatSession
    }

    func testMalformedRustSidecarPropagatesThroughChatModelLoader() async throws {
        let fixture = try await makePersistedFixture()
        defer {
            fixture.session.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try writeMalformedSidecar(fixture)
        let model = ChatModel(
            storedSessionsLoader: {
                try await fixture.engine.listChatSessions(
                    storageDir: fixture.storage.path
                )
            }
        )

        do {
            _ = try await model.storedSessions()
            XCTFail("malformed familiar metadata must fail the whole list")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("cannot parse familiar metadata"),
                error.localizedDescription
            )
        }
    }

    private func makePersistedFixture() async throws -> Fixture {
        let fileManager = FileManager.default
        let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "session-list-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let storage = root.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let engine = PocketEngine()
        guard engine.codexAccount() == nil else {
            throw XCTSkip("The integration fixture requires a signed-out Codex sandbox.")
        }
        let session = try await engine.startChat(
            provider: .codex, apiKey: "", model: "claude-test", effort: nil,
            workspaceDir: workspace.path, permissionMode: .default,
            storageDir: storage.path, familiar: nil, injectContext: false
        )
        do {
            try await session.send(
                prompt: "Persist this session",
                delegate: NoopSessionListChatDelegate()
            )
            XCTFail("unsigned Codex send should fail after persisting the prompt")
        } catch {
            let seeded = try await engine.listChatSessions(storageDir: storage.path)
            XCTAssertEqual(seeded.count, 1)
        }
        return Fixture(root: root, storage: storage, engine: engine, session: session)
    }

    private func writeMalformedSidecar(_ fixture: Fixture) throws {
        let metadata = fixture.storage.appendingPathComponent(
            "metadata",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: metadata,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: metadata.appendingPathComponent(
                "\(fixture.session.sessionId()).familiar.json"
            )
        )
    }
}
