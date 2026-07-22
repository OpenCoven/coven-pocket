import SwiftUI

/// Adaptive app root: the phone keeps the tab bar; regular-width iPad gets
/// a three-pane split — sections + sessions | selected section | context.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var router = AppRouter.shared

    var body: some View {
        if horizontalSizeClass == .regular {
            splitLayout
        } else {
            tabLayout
        }
    }

    // MARK: - iPad

    private var splitLayout: some View {
        NavigationSplitView {
            SidebarView(router: router)
        } content: {
            sectionView(for: router.selectedTab)
                .id(router.selectedTab)
        } detail: {
            if router.selectedTab == .chat {
                ContextPane()
            } else {
                ContentUnavailableView(
                    "No Context",
                    systemImage: "sidebar.right",
                    description: Text("Context appears alongside chat.")
                )
            }
        }
    }

    // MARK: - iPhone

    private var tabLayout: some View {
        TabView(selection: $router.selectedTab) {
            ForEach(AppRouter.Tab.allCases, id: \.self) { tab in
                sectionView(for: tab)
                    .tabItem { Label(tab.label, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
    }

    @ViewBuilder
    private func sectionView(for tab: AppRouter.Tab) -> some View {
        switch tab {
        case .chat: ChatView()
        case .repos: ReposView()
        case .companion: CompanionView()
        case .diff: DiffDemoView()
        case .playground: SpikeView()
        }
    }
}

/// iPad sidebar: app sections plus stored sessions with tap-to-resume.
private struct SidebarView: View {
    @ObservedObject var router: AppRouter
    @StateObject private var sessions = SidebarSessionsModel()

    var body: some View {
        List(selection: sectionSelection) {
            Section("Sections") {
                ForEach(AppRouter.Tab.allCases, id: \.self) { tab in
                    Label(tab.label, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            Section("Sessions") {
                if sessions.summaries.isEmpty {
                    Text("No stored sessions.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                ForEach(sessions.summaries, id: \.sessionId) { summary in
                    Button {
                        router.openSession(id: summary.sessionId)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title.isEmpty ? "Untitled session" : summary.title)
                                .lineLimit(1)
                            Text("\(summary.model) · \(summary.messageCount) messages")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
                .onDelete { offsets in
                    Task { await sessions.delete(at: offsets) }
                }
            }
        }
        .navigationTitle("Coven Pocket")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.startFreshChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New session")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .task { await sessions.refresh() }
        .refreshable { await sessions.refresh() }
    }

    /// Section rows select; session rows act as buttons instead.
    private var sectionSelection: Binding<AppRouter.Tab?> {
        Binding(
            get: { router.selectedTab },
            set: { if let tab = $0 { router.selectedTab = tab } }
        )
    }
}

/// Stored-session list state for the sidebar; resume itself routes through
/// `AppRouter` so the chat pane owns the actual engine session.
@MainActor
final class SidebarSessionsModel: ObservableObject {
    @Published var summaries: [ChatSessionSummary] = []

    private let engine = PocketEngine()

    func refresh() async {
        summaries = (try? await engine.listChatSessions(
            storageDir: ChatModel.sessionStoreURL.path
        )) ?? []
        SessionSpotlight.reindex(summaries)
    }

    func delete(at offsets: IndexSet) async {
        for index in offsets {
            guard summaries.indices.contains(index) else { continue }
            try? await engine.deleteChatSession(
                storageDir: ChatModel.sessionStoreURL.path,
                sessionId: summaries[index].sessionId
            )
        }
        await refresh()
    }
}
