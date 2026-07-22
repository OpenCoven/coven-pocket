import XCTest
@testable import CovenPocket

private final class FakeGistAPI: GistAPI {
    struct CreateCall: Equatable {
        let title: String
        let filename: String
        let content: String
        let token: String
    }

    var created: [CreateCall] = []
    var deleted: [(id: String, token: String)] = []
    var failCreate = false
    var failDelete = false

    struct Boom: Error {}

    func create(
        title: String, filename: String, content: String, token: String
    ) async throws -> GistShare {
        if failCreate { throw Boom() }
        created.append(
            CreateCall(title: title, filename: filename, content: content, token: token)
        )
        return GistShare(id: "g-\(created.count)", url: "https://gist.github.com/g", title: title, createdAt: .now)
    }

    func delete(id: String, token: String) async throws {
        if failDelete { throw Boom() }
        deleted.append((id, token))
    }
}

@MainActor
private func makeModel(api: FakeGistAPI) -> GistShareModel {
    let defaults = UserDefaults(suiteName: "gist-tests-\(UUID().uuidString)")!
    let model = GistShareModel(api: api, defaults: defaults)
    model.token = "tok-with-gist-scope"
    return model
}

final class GistShareTests: XCTestCase {
    // MARK: - Markdown export

    func testMarkdownRendersRolesToolsAndStatus() {
        let tool = ToolCallInfo(
            toolId: "t1", name: "Edit", inputSummary: "main.swift",
            result: "@@ -1,2 +1,2 @@\n-old\n+new", isError: false, isRunning: false
        )
        let items = [
            ChatItem(kind: .user, text: "fix the bug"),
            ChatItem(kind: .thinking, text: "reasoning here"),
            ChatItem(kind: .assistant, text: "Done."),
            ChatItem(kind: .tool, text: "", tool: tool),
            ChatItem(kind: .error, text: "network blip")
        ]
        let markdown = SessionExport.markdown(title: "T", items: items)

        XCTAssertTrue(markdown.hasPrefix("# T\n"))
        XCTAssertTrue(markdown.contains("## You\n\nfix the bug"))
        XCTAssertTrue(markdown.contains("<details><summary>Thinking</summary>"))
        XCTAssertTrue(markdown.contains("## Assistant\n\nDone."))
        XCTAssertTrue(markdown.contains("### Tool: Edit — main.swift"))
        XCTAssertTrue(markdown.contains("```diff\n@@ -1,2 +1,2 @@"))
        XCTAssertTrue(markdown.contains("> ⚠️ network blip"))
    }

    func testFencingEscalatesPastEmbeddedBackticks() {
        let fencedBlock = SessionExport.fenced("uses ```swift inside")
        XCTAssertTrue(fencedBlock.hasPrefix("````\n"), fencedBlock)
        XCTAssertTrue(fencedBlock.hasSuffix("\n````"), fencedBlock)
    }

    func testTitleComesFromFirstUserMessage() {
        let long = String(repeating: "x", count: 80)
        XCTAssertEqual(SessionExport.title(for: []), "Coven Pocket session")
        XCTAssertEqual(
            SessionExport.title(for: [ChatItem(kind: .user, text: "short ask\nmore")]),
            "short ask"
        )
        XCTAssertEqual(
            SessionExport.title(for: [ChatItem(kind: .user, text: long)]).count,
            58
        )
    }

    // MARK: - Redaction integration (real engine FFI)

    @MainActor
    func testPrepareRedactsSecretsBeforePreview() async {
        let model = makeModel(api: FakeGistAPI())
        let items = [
            ChatItem(kind: .user, text: "my token is ghp_abcdefghijklmnopqrstuvwxyz012345")
        ]

        await model.prepare(items: items)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.preview.contains("ghp_abcdefghijklmnop"))
        XCTAssertTrue(model.preview.contains("[REDACTED:github token]"))
        XCTAssertEqual(model.findings.first?.label, "GitHub token")
    }

    // MARK: - Upload / revoke lifecycle

    @MainActor
    func testUploadSendsRedactedPreviewAndRecordsShare() async {
        let api = FakeGistAPI()
        let model = makeModel(api: api)
        await model.prepare(items: [
            ChatItem(kind: .user, text: "key sk-abcdefghijklmnopqrstu here")
        ])

        await model.upload()

        guard case .shared(let share) = model.phase else {
            return XCTFail("expected shared, got \(model.phase)")
        }
        XCTAssertEqual(api.created.count, 1)
        XCTAssertFalse(api.created[0].content.contains("sk-abcdefghijklmnopqrstu"))
        XCTAssertTrue(api.created[0].content.contains("[REDACTED:api key]"))
        XCTAssertEqual(model.pastShares, [share])
    }

    @MainActor
    func testUploadRequiresTokenAndReadyPhase() async {
        let api = FakeGistAPI()
        let model = makeModel(api: api)
        await model.prepare(items: [ChatItem(kind: .user, text: "hi")])
        model.token = ""

        await model.upload()

        guard case .failed = model.phase else {
            return XCTFail("expected failure without token")
        }
        XCTAssertTrue(api.created.isEmpty)

        model.resetToReady()
        XCTAssertEqual(model.phase, .ready)
    }

    @MainActor
    func testRevokeDeletesAndForgetsShare() async {
        let api = FakeGistAPI()
        let model = makeModel(api: api)
        await model.prepare(items: [ChatItem(kind: .user, text: "hi")])
        await model.upload()
        guard case .shared(let share) = model.phase else {
            return XCTFail("expected shared")
        }

        await model.revoke(share)

        XCTAssertEqual(api.deleted.first?.id, share.id)
        XCTAssertTrue(model.pastShares.isEmpty)
        XCTAssertEqual(model.phase, .ready)
    }
}
