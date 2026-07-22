import XCTest
@testable import CovenPocket

/// End-to-end memory FFI: notes round-trip through the per-workspace memdir
/// and the composed context picks up both AGENTS.md and note content.
final class MemoryTests: XCTestCase {
    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testNoteRoundTrip() async throws {
        let engine = PocketEngine()
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try await engine.writeMemoryNote(
            workspaceDir: workspace.path,
            filename: "deploy.md",
            content: "---\nname: Deploy steps\ntype: project\n---\nAlways run the smoke test."
        )

        let notes = try await engine.listMemoryNotes(workspaceDir: workspace.path)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].filename, "deploy.md")
        XCTAssertEqual(notes[0].displayName, "Deploy steps")
        XCTAssertEqual(notes[0].noteType, "project")

        let content = try await engine.readMemoryNote(
            workspaceDir: workspace.path, filename: "deploy.md"
        )
        XCTAssertTrue(content.contains("smoke test"))

        try await engine.deleteMemoryNote(
            workspaceDir: workspace.path, filename: "deploy.md"
        )
        let remaining = try await engine.listMemoryNotes(workspaceDir: workspace.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTraversalFilenamesAreRejected() async throws {
        let engine = PocketEngine()
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        for bad in ["../evil.md", "nested/dir.md", ".hidden.md", "notes.txt", "MEMORY.md"] {
            do {
                try await engine.writeMemoryNote(
                    workspaceDir: workspace.path, filename: bad, content: "nope"
                )
                XCTFail("filename '\(bad)' must be rejected")
            } catch {
                // expected
            }
        }
    }

    func testProjectContextComposesAgentsAndNotes() async throws {
        let engine = PocketEngine()
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "Pocket rule: prefer small diffs.".write(
            to: workspace.appendingPathComponent("AGENTS.md"),
            atomically: true, encoding: .utf8
        )
        try await engine.writeMemoryNote(
            workspaceDir: workspace.path,
            filename: "style.md",
            content: "Use tabs, never spaces."
        )

        let context = try await engine.projectContext(workspaceDir: workspace.path)
        XCTAssertTrue(context.text.contains("prefer small diffs"))
        XCTAssertTrue(context.text.contains("Use tabs, never spaces."))
        XCTAssertFalse(context.truncated)
        XCTAssertEqual(context.sources.count, 2)
    }

    func testEmptyWorkspaceHasEmptyContext() async throws {
        let engine = PocketEngine()
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = try await engine.projectContext(workspaceDir: workspace.path)
        XCTAssertTrue(context.text.isEmpty)
        XCTAssertTrue(context.sources.isEmpty)
    }
}
