import XCTest
@testable import CovenPocket

final class EngineSmokeTests: XCTestCase {
    func testEngineVersionIsNonEmpty() {
        let engine = PocketEngine()
        XCTAssertFalse(engine.engineVersion().isEmpty)
    }

    func testDefaultModelIsNonEmpty() {
        let engine = PocketEngine()
        XCTAssertFalse(engine.defaultModel().isEmpty)
    }

    func testDefaultCodexModelIsNonEmpty() {
        let engine = PocketEngine()
        XCTAssertFalse(engine.defaultCodexModel().isEmpty)
    }

    func testCodexStartsSignedOut() {
        // Fresh simulator sandbox: no stored tokens, so no account and the
        // model catalog refuses until sign-in.
        let engine = PocketEngine()
        XCTAssertNil(engine.codexAccount())
    }

    func testCodexModelListRequiresSignIn() async {
        let engine = PocketEngine()
        guard engine.codexAccount() == nil else {
            // A signed-in sandbox (developer device) — nothing to assert.
            return
        }
        do {
            _ = try await engine.listCodexModels()
            XCTFail("expected listCodexModels to throw when signed out")
        } catch {
            // Expected: provider error about missing sign-in.
        }
    }
}
