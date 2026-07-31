import SwiftUI
import CoreSpotlight

@MainActor
struct CovenPocketAppDependencies {
    let engineClient: EngineClient

    static func live() -> Self {
        Self(engineClient: EngineClient())
    }
}

@main
struct CovenPocketApp: App {
    @StateObject private var router = AppRouter.shared
    @StateObject private var engineClient: EngineClient
    let rootWindowFactory: RootWindowFactory

    init() {
        self.init(dependencies: .live())
    }

    init(dependencies: CovenPocketAppDependencies) {
        _engineClient = StateObject(
            wrappedValue: dependencies.engineClient
        )
        rootWindowFactory = RootWindowFactory(
            client: dependencies.engineClient
        )
    }

    var body: some Scene {
        WindowGroup {
            rootWindowFactory.makeRoot()
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
