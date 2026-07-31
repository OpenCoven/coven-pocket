import Combine
import SwiftUI

@MainActor
final class CodexAccountTransitionObserver {
    private var profileID: String?
    private var observation: AnyCancellable?

    init(
        client: EngineClient,
        onTransition: @escaping (String?, String?) -> Void
    ) {
        profileID = client.codexAccount?.profileId
        observation = client.$codexAccount
            .map { $0?.profileId }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] newProfileID in
                guard let self else { return }
                let oldProfileID = profileID
                profileID = newProfileID
                onTransition(oldProfileID, newProfileID)
            }
    }
}

@MainActor
final class RootWindowState: ObservableObject {
    let client: EngineClient
    let chatState: ChatSurfaceState

    private var accountObserver: CodexAccountTransitionObserver?

    convenience init(client: EngineClient) {
        self.init(client: client, chatState: ChatSurfaceState())
    }

    init(client: EngineClient, chatState: ChatSurfaceState) {
        self.client = client
        self.chatState = chatState
        accountObserver = CodexAccountTransitionObserver(client: client) {
            chatState.handleCodexAccountTransition(from: $0, to: $1)
        }
    }

    var sectionFactory: RootSectionFactory {
        RootSectionFactory(client: client, chatState: chatState)
    }
}

/// Adaptive app root: the phone keeps the tab bar; regular-width iPad gets
/// a three-pane split — sections + sessions | selected section | context.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var windowState: RootWindowState
    @ObservedObject private var router = AppRouter.shared

    init(client: EngineClient) {
        self.init(windowState: RootWindowState(client: client))
    }

    init(client: EngineClient, chatState: ChatSurfaceState) {
        self.init(
            windowState: RootWindowState(
                client: client,
                chatState: chatState
            )
        )
    }

    init(windowState: RootWindowState) {
        _windowState = StateObject(
            wrappedValue: windowState
        )
    }

    init(standaloneClient client: EngineClient) {
        self.init(client: client)
    }

    var sectionFactory: RootSectionFactory {
        windowState.sectionFactory
    }

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
            SidebarView(
                router: router,
                chatModel: windowState.chatState.model
            )
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
        case .chat: sectionFactory.chat()
        case .repos: ReposView()
        case .companion: CompanionView()
        case .diff: DiffDemoView()
        case .playground: sectionFactory.playground()
        }
    }
}

@MainActor
struct RootWindowFactory {
    let client: EngineClient

    func makeWindowState() -> RootWindowState {
        RootWindowState(client: client)
    }

    func makeWindowState(chatState: ChatSurfaceState) -> RootWindowState {
        RootWindowState(client: client, chatState: chatState)
    }

    func makeRoot() -> RootView {
        RootView(windowState: makeWindowState())
    }

    func makeRoot(chatState: ChatSurfaceState) -> RootView {
        RootView(windowState: makeWindowState(chatState: chatState))
    }
}

@MainActor
struct RootSectionFactory {
    let client: EngineClient
    let chatState: ChatSurfaceState

    func chat() -> ChatView {
        ChatView(client: client, chatState: chatState)
    }

    func playground() -> SpikeView {
        SpikeView(client: client)
    }
}

/// iPad sidebar: app sections plus stored sessions with tap-to-resume.
private struct SidebarView: View {
    @ObservedObject var router: AppRouter
    @ObservedObject var chatModel: ChatModel
    @StateObject private var sessions: SidebarSessionsModel
    @State private var pendingDelete: [ChatSessionSummary]?

    init(router: AppRouter, chatModel: ChatModel) {
        self.router = router
        self.chatModel = chatModel
        _sessions = StateObject(
            wrappedValue: SidebarSessionsModel(chatModel: chatModel)
        )
    }

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
                    switch sessions.loadState {
                    case .idle, .loading:
                        ProgressView("Loading sessions")
                            .font(.footnote)
                    case .failed:
                        SessionListErrorRow(error: .load) {
                            Task { await sessions.refresh() }
                        }
                    case .loaded:
                        Text("No stored sessions.")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                } else if sessions.loadError != nil {
                    SessionListErrorRow(error: .load) {
                        Task { await sessions.refresh() }
                    }
                }
                if let error = sessions.operationError {
                    SessionListErrorRow(error: error) {
                        Task { await sessions.refresh() }
                    }
                }
                ForEach(sessions.summaries, id: \.sessionId) { summary in
                    Button {
                        router.openSession(id: summary.sessionId)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.displayTitle)
                                .lineLimit(1)
                            Text(summary.sidebarSubtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .deleteDisabled(
                        sessions.isMutating ||
                            !chatModel.canDeleteSession(summary)
                    )
                }
                .onDelete { offsets in
                    let selected = offsets.compactMap { index in
                        sessions.summaries.indices.contains(index)
                            ? sessions.summaries[index]
                            : nil
                    }
                    pendingDelete = selected.isEmpty ? nil : selected
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
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { summaries in
            Button("Delete", role: .destructive) {
                Task { await sessions.delete(summaries) }
            }
            .disabled(sessions.isMutating)
        } message: { _ in
            Text("The transcript is removed from this device.")
        }
    }

    /// Section rows select; session rows act as buttons instead.
    private var sectionSelection: Binding<AppRouter.Tab?> {
        Binding(
            get: { router.selectedTab },
            set: { if let tab = $0 { router.selectedTab = tab } }
        )
    }
}

extension ChatSessionSummary {
    /// "model · N messages", omitting the model when the summary lacks one.
    var sidebarSubtitle: String {
        let messages = "\(messageCount) messages"
        return model.isEmpty ? messages : "\(model) · \(messages)"
    }
}
