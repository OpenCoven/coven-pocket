import ActivityKit
import SwiftUI
import WidgetKit

struct GoalLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GoalActivityAttributes.self) { context in
            HStack {
                Image(systemName: "target")
                VStack(alignment: .leading) {
                    Text(context.attributes.objective).lineLimit(1)
                    Text("\(context.state.status.capitalized) · turn \(context.state.turnsUsed)/\(context.state.maxTurns)")
                        .font(.caption)
                }
            }
            .activityBackgroundTint(.indigo)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "target") }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.turnsUsed)/\(context.state.maxTurns)")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.objective).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "target")
            } compactTrailing: {
                Text("\(context.state.turnsUsed)")
            } minimal: {
                Image(systemName: "target")
            }
        }
    }
}

@main
struct CovenPocketGoalWidgets: WidgetBundle {
    var body: some Widget {
        GoalLiveActivityWidget()
    }
}
