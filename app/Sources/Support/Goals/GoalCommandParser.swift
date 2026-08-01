import Foundation

enum GoalCommand: Equatable {
    case start(objective: String, tokenBudget: UInt64?)
    case status
    case pause
    case resume
    case clear
}

enum GoalCommandParseResult: Equatable {
    case notGoal
    case command(GoalCommand)
    case error(String)
}

enum GoalCommandParser {
    static let usage =
        "Use /goal <objective>, /goal --tokens <budget> <objective>, "
        + "/goal status, /goal pause, /goal resume, or /goal clear."

    static func parse(_ input: String) -> GoalCommandParseResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "/goal" || trimmed.hasPrefix("/goal ") || trimmed.hasPrefix("/goal\t") else {
            return .notGoal
        }

        let remainder = String(trimmed.dropFirst("/goal".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return .error(usage) }

        switch remainder {
        case "status": return .command(.status)
        case "pause": return .command(.pause)
        case "resume": return .command(.resume)
        case "clear": return .command(.clear)
        default: break
        }

        if remainder.hasPrefix("--tokens") {
            let parts = remainder.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard parts.count == 3, parts[0] == "--tokens",
                  let budget = UInt64(parts[1]),
                  budget > 0,
                  budget <= UInt64(Int64.max)
            else { return .error(usage) }
            let objective = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            return objective.isEmpty ? .error(usage) : .command(.start(objective: objective, tokenBudget: budget))
        }

        guard !remainder.hasPrefix("--") else { return .error(usage) }
        return .command(.start(objective: remainder, tokenBudget: nil))
    }
}
