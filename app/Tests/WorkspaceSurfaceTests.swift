import XCTest
@testable import CovenPocket

final class WorkspaceSurfaceTests: XCTestCase {
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

    // MARK: - Companion / daemon probe

    @MainActor
    func testCompanionConfigPersistsAndValidates() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "companion-\(UUID().uuidString)"))
        let model = CompanionModel(defaults: defaults)
        XCTAssertEqual(model.portText, "7777")
        XCTAssertFalse(model.canProbe) // no host yet

        model.host = "mac.tailnet.ts.net"
        XCTAssertTrue(model.canProbe)
        XCTAssertEqual(defaults.string(forKey: CompanionModel.hostKey), "mac.tailnet.ts.net")

        model.portText = "not a port"
        XCTAssertNil(model.port)
        XCTAssertFalse(model.canProbe)
        model.portText = "8022"
        XCTAssertEqual(model.port, 8022)

        // A fresh model restores the saved connection.
        let restored = CompanionModel(defaults: defaults)
        XCTAssertEqual(restored.host, "mac.tailnet.ts.net")
        XCTAssertEqual(restored.port, 8022)
    }

    @MainActor
    func testProbeStatesMapToActionableCopy() {
        let reachable = CompanionModel.status(
            from: .reachable(pid: 42, startedAt: "2026-01-01T00:00:00Z", latencyMs: 12)
        )
        XCTAssertEqual(reachable, .reachable(pid: 42, latencyMs: 12))

        for (state, expectedReason) in [
            (DaemonProbeState.refused, "Connection refused"),
            (.timedOut, "Timed out"),
            (.unresolvable, "Host not found"),
            (.notADaemon(detail: "nginx answered"), "Not a Coven daemon"),
            (.failed(detail: "boom"), "Connection failed")
        ] {
            guard case let .failed(reason, hint) = CompanionModel.status(from: state) else {
                return XCTFail("expected .failed for \(state)")
            }
            XCTAssertEqual(reason, expectedReason)
            XCTAssertFalse(hint.isEmpty)
        }
    }

    func testLiveProbeReportsRefusedLocally() async {
        // Nothing listens on this port on the simulator host.
        let engine = PocketEngine()
        let state = await engine.probeDaemon(host: "127.0.0.1", port: 1, timeoutMs: 2000)
        guard case .refused = state else {
            return XCTFail("expected .refused, got \(state)")
        }
    }
}
