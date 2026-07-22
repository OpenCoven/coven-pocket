import SwiftUI

@main
struct CovenPocketApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ChatView()
                    .tabItem {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                ReposView()
                    .tabItem {
                        Label("Repos", systemImage: "arrow.triangle.branch")
                    }
                CompanionView()
                    .tabItem {
                        Label("Companion", systemImage: "antenna.radiowaves.left.and.right")
                    }
                SpikeView()
                    .tabItem {
                        Label("Playground", systemImage: "testtube.2")
                    }
            }
        }
    }
}
