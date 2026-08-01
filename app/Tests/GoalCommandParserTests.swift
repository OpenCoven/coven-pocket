import XCTest
@testable import CovenPocket

final class GoalCommandParserTests: XCTestCase {
    func testNonGoalTextPassesThrough() {
        XCTAssertEqual(GoalCommandParser.parse("hello"), .notGoal)
        XCTAssertEqual(GoalCommandParser.parse("/goalie"), .notGoal)
    }

    func testStartCommandsPreserveObjectiveAndBudget() {
        XCTAssertEqual(
            GoalCommandParser.parse(" /goal ship the feature "),
            .command(.start(objective: "ship the feature", tokenBudget: nil))
        )
        XCTAssertEqual(
            GoalCommandParser.parse("/goal --tokens 12000 ship it"),
            .command(.start(objective: "ship it", tokenBudget: 12_000))
        )
    }

    func testExactActionsHaveNoArguments() {
        XCTAssertEqual(GoalCommandParser.parse("/goal status"), .command(.status))
        XCTAssertEqual(GoalCommandParser.parse("/goal pause"), .command(.pause))
        XCTAssertEqual(GoalCommandParser.parse("/goal resume"), .command(.resume))
        XCTAssertEqual(GoalCommandParser.parse("/goal clear"), .command(.clear))
        XCTAssertEqual(
            GoalCommandParser.parse("/goal status page rollout"),
            .command(.start(objective: "status page rollout", tokenBudget: nil))
        )
    }

    func testMalformedBudgetAndMissingObjectiveAreLocalErrors() {
        for input in [
            "/goal", "/goal --tokens", "/goal --tokens 0 ship",
            "/goal --tokens nope ship", "/goal --tokens 9223372036854775808 ship",
            "/goal --tokens 18446744073709551616 ship", "/goal --unknown ship"
        ] {
            guard case .error = GoalCommandParser.parse(input) else {
                return XCTFail("expected local error for \(input)")
            }
        }
    }
}
