import XCTest
@testable import CovenPocket

@MainActor
final class AppIntentsTests: XCTestCase {
    // MARK: - Router

    func testRouterRequestsAreConsumedOnce() {
        let router = AppRouter()

        router.openChat(prompt: "fix the tests")
        XCTAssertEqual(router.selectedTab, .chat)
        XCTAssertEqual(router.consumePrompt(), "fix the tests")
        XCTAssertNil(router.consumePrompt(), "a queued prompt must not replay")

        router.openSession(id: "abc-123")
        XCTAssertEqual(router.consumeSessionID(), "abc-123")
        XCTAssertNil(router.consumeSessionID())

        router.startFreshChat()
        XCTAssertTrue(router.consumeReset())
        XCTAssertFalse(router.consumeReset())
    }

    func testRouterIgnoresBlankPrompts() {
        let router = AppRouter()
        router.openChat(prompt: "   \n")
        XCTAssertNil(router.consumePrompt())
    }

    // MARK: - Intent actions

    func testAskRebindsWorkspaceAndQueuesPrompt() {
        let router = AppRouter()
        let defaults = UserDefaults(suiteName: "intent-tests-\(UUID().uuidString)")!
        let workspace = WorkspaceEntity(id: "/tmp/repos/api", name: "api")

        IntentActions.ask(
            prompt: "run the linter", workspace: workspace,
            router: router, defaults: defaults
        )

        XCTAssertEqual(defaults.string(forKey: ChatModel.activeWorkspacePathKey), "/tmp/repos/api")
        XCTAssertEqual(defaults.string(forKey: RepoModel.activeRepoNameKey), "api")
        XCTAssertEqual(router.consumePrompt(), "run the linter")
    }

    func testAskWithoutWorkspaceLeavesBindingAlone() {
        let router = AppRouter()
        let defaults = UserDefaults(suiteName: "intent-tests-\(UUID().uuidString)")!
        defaults.set("/existing", forKey: ChatModel.activeWorkspacePathKey)

        IntentActions.ask(prompt: "hello", workspace: nil, router: router, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: ChatModel.activeWorkspacePathKey), "/existing")
        XCTAssertEqual(router.consumePrompt(), "hello")
    }

    // MARK: - Workspace entities

    func testWorkspaceEntitiesListDirectoriesOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-repos-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["zeta", "alpha"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("stray.txt").path, contents: Data()
        )

        let entities = WorkspaceEntity.workspaces(under: root)
        XCTAssertEqual(entities.map(\.name), ["alpha", "zeta"])
        XCTAssertTrue(entities.allSatisfy { $0.id.hasSuffix($0.name) })
    }

    // MARK: - Spotlight

    func testSearchableItemsCarrySessionAttributes() {
        let summary = ChatSessionSummary(
            sessionId: "11111111-2222-3333-4444-555555555555",
            title: "Fix the parser",
            model: "claude-test",
            createdAt: "2026-07-20T10:00:00Z",
            updatedAt: "2026-07-21T11:30:00Z",
            messageCount: 7
        )

        let items = SessionSpotlight.searchableItems(for: [summary])
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.uniqueIdentifier, "session:11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(item.domainIdentifier, SessionSpotlight.domain)
        XCTAssertEqual(item.attributeSet.title, "Fix the parser")
        XCTAssertEqual(item.attributeSet.contentDescription, "claude-test · 7 messages")
        XCTAssertNotNil(item.attributeSet.contentModificationDate)
    }

    func testSearchableItemsFallBackToUntitled() {
        let summary = ChatSessionSummary(
            sessionId: "id", title: "", model: "m",
            createdAt: "", updatedAt: "not-a-date", messageCount: 0
        )
        let item = SessionSpotlight.searchableItems(for: [summary])[0]
        XCTAssertEqual(item.attributeSet.title, "Untitled session")
        XCTAssertNil(item.attributeSet.contentModificationDate)
    }

    func testSessionIDRoundTripsThroughIdentifier() {
        XCTAssertEqual(
            SessionSpotlight.sessionID(fromUniqueIdentifier: "session:abc"), "abc"
        )
        XCTAssertNil(SessionSpotlight.sessionID(fromUniqueIdentifier: "other:abc"))
        XCTAssertNil(SessionSpotlight.sessionID(fromUniqueIdentifier: "session:"))
    }
}
