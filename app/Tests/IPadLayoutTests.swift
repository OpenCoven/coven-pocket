import XCTest
@testable import CovenPocket

@MainActor
final class IPadLayoutTests: XCTestCase {
    // MARK: - Section shortcuts

    func testShortcutDigitsMapToSectionsInOrder() {
        XCTAssertEqual(AppRouter.Tab.forShortcut(1), .chat)
        XCTAssertEqual(AppRouter.Tab.forShortcut(2), .repos)
        XCTAssertEqual(AppRouter.Tab.forShortcut(3), .companion)
        XCTAssertEqual(AppRouter.Tab.forShortcut(4), .diff)
        XCTAssertEqual(AppRouter.Tab.forShortcut(5), .playground)
        XCTAssertNil(AppRouter.Tab.forShortcut(0))
        XCTAssertNil(AppRouter.Tab.forShortcut(6))
    }

    func testEverySectionHasDisplayMetadata() {
        for tab in AppRouter.Tab.allCases {
            XCTAssertFalse(tab.label.isEmpty, "\(tab) needs a label")
            XCTAssertFalse(tab.systemImage.isEmpty, "\(tab) needs a symbol")
        }
    }

    // MARK: - Context status line

    private func summary(
        branch: String, dirty: UInt32, ahead: UInt32, behind: UInt32
    ) -> GitWorkspaceSummary {
        GitWorkspaceSummary(
            name: "api", path: "/repos/api", branch: branch,
            remoteUrl: nil, dirtyCount: dirty, ahead: ahead, behind: behind
        )
    }

    func testStatusLineShowsOnlyNonZeroParts() {
        XCTAssertEqual(
            ContextPane.statusLine(for: summary(branch: "main", dirty: 0, ahead: 0, behind: 0)),
            "main"
        )
        XCTAssertEqual(
            ContextPane.statusLine(for: summary(branch: "main", dirty: 3, ahead: 0, behind: 0)),
            "main · 3 changed"
        )
        XCTAssertEqual(
            ContextPane.statusLine(for: summary(branch: "dev", dirty: 1, ahead: 2, behind: 4)),
            "dev · 1 changed · ↑2 ↓4"
        )
        XCTAssertEqual(
            ContextPane.statusLine(for: summary(branch: "dev", dirty: 0, ahead: 0, behind: 7)),
            "dev · ↓7"
        )
    }
}
