import SwiftUI
import CoreSpotlight

@main
struct CovenPocketApp: App {
    @StateObject private var router = AppRouter.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                // Spotlight result taps arrive as index continuations.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard
                        let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier]
                            as? String,
                        let sessionID = SessionSpotlight.sessionID(
                            fromUniqueIdentifier: identifier
                        )
                    else { return }
                    router.openSession(id: sessionID)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { router.startFreshChat() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Go") {
                ForEach(Array(AppRouter.Tab.allCases.enumerated()), id: \.element) { index, tab in
                    Button(tab.label) { router.selectedTab = tab }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(index + 1)")), modifiers: .command
                        )
                }
            }
        }
    }
}
