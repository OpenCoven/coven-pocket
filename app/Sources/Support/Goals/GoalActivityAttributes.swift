import ActivityKit
import Foundation

struct GoalActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let status: String
        let turnsUsed: UInt32
        let maxTurns: UInt32
        let tokensUsed: UInt64
        let tokenBudget: UInt64?
    }

}
