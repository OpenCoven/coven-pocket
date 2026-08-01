import ActivityKit
import Foundation

@MainActor
final class GoalActivityCoordinator {
    private var activity: Activity<GoalActivityAttributes>?

    func update(_ snapshot: GoalSnapshot) async {
        let attributes = GoalActivityAttributes()
        let content = ActivityContent(state: state(for: snapshot), staleDate: nil)
        do {
            if let activity {
                await activity.update(content)
            } else {
                activity = try Activity.request(attributes: attributes, content: content)
            }
        } catch {
            // Live Activities are optional presentation; durable goal state is
            // always owned by the Rust store and must continue without one.
        }
    }

    func apply(_ result: GoalRunResult) async {
        if let snapshot = result.snapshot,
           snapshot.status == .active || snapshot.status == .paused {
            await update(snapshot)
        } else {
            await end()
        }
    }

    func end() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }

    private func state(for snapshot: GoalSnapshot) -> GoalActivityAttributes.ContentState {
        GoalActivityAttributes.ContentState(
            status: String(describing: snapshot.status).lowercased(),
            turnsUsed: snapshot.turnsUsed,
            maxTurns: snapshot.maxTurns,
            tokensUsed: snapshot.tokensUsed,
            tokenBudget: snapshot.tokenBudget
        )
    }
}
