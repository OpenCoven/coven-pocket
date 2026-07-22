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
                SpikeView()
                    .tabItem {
                        Label("Playground", systemImage: "testtube.2")
                    }
            }
        }
    }
}
