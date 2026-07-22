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
            workspaceDir: workspace.path
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
            workspaceDir: workspace.path
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
                workspaceDir: "relative/workspace"
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
}
