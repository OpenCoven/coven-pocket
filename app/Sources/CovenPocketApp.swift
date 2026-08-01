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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var router = AppRouter.shared
    @StateObject private var rootWindowState: RootWindowState
    let rootWindowFactory: RootWindowFactory

    init() {
        self.init(dependencies: .live())
    }

    init(dependencies: CovenPocketAppDependencies) {
        let factory = RootWindowFactory(
            client: dependencies.engineClient
        )
        rootWindowFactory = factory
        _rootWindowState = StateObject(
            wrappedValue: factory.makeWindowState()
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(windowState: rootWindowState)
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
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background else { return }
                    Task { await rootWindowState.chatState.model.pauseGoalForBackground() }
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
