import SwiftUI
import CoreSpotlight

@main
struct CovenPocketApp: App {
    @StateObject private var router = AppRouter.shared

    var body: some Scene {
        WindowGroup {
            TabView(selection: $router.selectedTab) {
                ChatView()
                    .tabItem {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                    .tag(AppRouter.Tab.chat)
                ReposView()
                    .tabItem {
                        Label("Repos", systemImage: "arrow.triangle.branch")
                    }
                    .tag(AppRouter.Tab.repos)
                CompanionView()
                    .tabItem {
                        Label("Companion", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .tag(AppRouter.Tab.companion)
                DiffDemoView()
                    .tabItem {
                        Label("Diff", systemImage: "plus.forwardslash.minus")
                    }
                    .tag(AppRouter.Tab.diff)
                SpikeView()
                    .tabItem {
                        Label("Playground", systemImage: "testtube.2")
                    }
                    .tag(AppRouter.Tab.playground)
            }
            // Spotlight result taps arrive as index continuations.
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard
                    let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier]
                        as? String,
                    let sessionID = SessionSpotlight.sessionID(fromUniqueIdentifier: identifier)
                else { return }
                router.openSession(id: sessionID)
            }
        }
    }
}
