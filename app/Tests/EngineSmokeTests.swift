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
}
