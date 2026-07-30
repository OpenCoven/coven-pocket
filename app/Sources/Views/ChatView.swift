import SwiftUI

/// Multi-turn chat through either a verified companion daemon's Claude CLI
/// or the on-device Codex engine.
struct ChatView: View {
    @StateObject private var model = ChatModel()
    @StateObject private var client = EngineClient()
    @StateObject private var companionModel = CompanionChatModel()
    @ObservedObject private var router = AppRouter.shared

    @State private var settings = ChatSettings(
        daemonProjectRoot: UserDefaults.standard.string(
            forKey: "daemon-chat-project-root"
        ) ?? ""
    )
    @State private var prompt = ""
    @State private var showSettings = false
    @State private var showSessions = false
    @State private var showShare = false

    private var activeItems: [ChatItem] {
        settings.backend == .companionClaude ? companionModel.items : model.items
    }

    private var activeIsBusy: Bool {
        settings.backend == .companionClaude ? companionModel.isBusy : model.isBusy
    }

    private var activeCanRetry: Bool {
        settings.backend == .companionClaude ? companionModel.canRetry : model.canRetry
    }

    private var canSend: Bool {
        guard !activeIsBusy,
              !(settings.backend == .companionClaude && companionModel.hasPendingCleanup),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        switch settings.backend {
        case .companionClaude:
            return companionModel.isAvailable
                && CompanionChatModel.isAbsoluteHostPath(settings.daemonProjectRoot)
        case .codex:
            return client.codexAccount != nil && !settings.model.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                Divider()
                inputBar
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if settings.backend == .codex {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Permission mode", selection: $model.permissionMode) {
                                ForEach(ChatPermissionMode.all, id: \.self) { mode in
                                    Label(mode.label, systemImage: mode.symbolName)
                                        .tag(mode)
                                }
                            }
                        } label: {
                            Image(systemName: model.permissionMode.symbolName)
                        }
                        .accessibilityLabel("Permission mode")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(activeItems.isEmpty)
                    .accessibilityLabel("Share session")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSessions = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Sessions")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Chat settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                ChatSettingsView(
                    settings: $settings,
                    client: client,
                    model: model,
                    companionModel: companionModel
                )
            }
            .sheet(isPresented: $showSessions) {
                if settings.backend == .companionClaude {
                    NavigationStack {
                        RemoteSessionsView(
                            companion: companionModel.companion,
                            showsDoneButton: true
                        )
                    }
                } else {
                    SessionsView(model: model, settings: settings)
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSessionSheet(items: activeItems)
            }
            .sheet(item: $model.pendingApproval, onDismiss: model.approvalDismissed) { approval in
                ApprovalSheet(approval: approval, model: model)
                    .presentationDetents([.medium, .large])
            }
            .task {
                if settings.model.isEmpty {
                    settings.model = client.defaultCodexModel
                }
            }
            .task(id: router.selectedTab) {
                if router.selectedTab == .chat {
                    await companionModel.refreshAvailability()
                    normalizeBackendSelection()
                }
            }
            .task(id: router.pendingPrompt) { await consumeRouterPrompt() }
            .task(id: router.pendingSessionID) { await consumeRouterSession() }
            .task(id: router.pendingReset) {
                guard router.consumeReset() else { return }
                await resetActiveConversation()
            }
        }
    }
}

private extension ChatView {
    // MARK: - Intent / Spotlight handoff

    /// Run a prompt queued by `AskCovenIntent`: send it when the backend is
    /// configured, otherwise leave it in the input bar for the user.
    /// Consuming clears the published value (changing the task id), so the
    /// actual work runs in a detached-lifetime `Task` that survives the
    /// resulting cancellation.
    private func consumeRouterPrompt() async {
        guard let queued = router.consumePrompt() else { return }
        prompt = queued
        guard canSend else { return }
        prompt = ""
        Task { await send(queued) }
    }

    /// Spotlight indexes on-device sessions, so this explicit history choice
    /// switches to Codex rather than acting as an error fallback.
    private func consumeRouterSession() async {
        guard let sessionID = router.consumeSessionID() else { return }
        settings.backend = .codex
        if settings.model.isEmpty {
            settings.model = client.defaultCodexModel
        }
        let settings = settings
        Task {
            guard
                let summary = await model.storedSessions()
                    .first(where: { $0.sessionId == sessionID })
            else { return }
            await model.resume(summary, settings: settings)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if activeItems.isEmpty {
                        emptyState
                    }
                    ForEach(activeItems) { item in
                        ChatRow(item: item)
                            .id(item.id)
                    }
                    if activeCanRetry {
                        Button("Retry") {
                            Task { await retryActiveConversation() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .onChange(of: activeItems.last?.text) {
                if let last = activeItems.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(settings.backend == .companionClaude ? "Claude via Companion" : "On-device Codex")
                .font(.headline)
            Text(emptyStateDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private var emptyStateDescription: String {
        switch settings.backend {
        case .companionClaude:
            return "Claude runs on the paired daemon using the host's signed-in CLI "
                + "and works in the explicit host project path."
        case .codex:
            return "Codex can read, search, and edit files inside this app's workspace. "
                + "Shell and network tools are not available on device."
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $prompt, axis: .vertical)
                .lineLimit(1 ... 4)
                .textFieldStyle(.roundedBorder)

            if activeIsBusy {
                Button {
                    Task { await stopActiveConversation() }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .accessibilityLabel("Stop")
            } else {
                Button {
                    let text = prompt
                    prompt = ""
                    Task { await send(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
                // Hardware keyboards (iPad) send with Cmd+Return.
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func send(_ text: String) async {
        switch settings.backend {
        case .companionClaude:
            await companionModel.send(
                prompt: text,
                projectRoot: settings.daemonProjectRoot
            )
        case .codex:
            await model.send(prompt: text, settings: settings)
        }
    }

    private func retryActiveConversation() async {
        switch settings.backend {
        case .companionClaude:
            await companionModel.retry()
        case .codex:
            await model.retry()
        }
    }

    private func stopActiveConversation() async {
        switch settings.backend {
        case .companionClaude:
            await companionModel.stop()
        case .codex:
            model.stop()
        }
    }

    private func resetActiveConversation() async {
        switch settings.backend {
        case .companionClaude:
            await companionModel.reset()
        case .codex:
            model.reset()
        }
    }

    private func normalizeBackendSelection() {
        guard companionModel.availability != .checking else { return }
        let available = ChatBackend.available(
            companionAvailable: companionModel.isAvailable,
            codexAvailable: client.codexAccount != nil
        )
        guard !available.contains(settings.backend),
              let fallback = available.first else {
            return
        }
        settings.backend = fallback
        if fallback == .codex, settings.model.isEmpty {
            settings.model = client.defaultCodexModel
        }
    }
}

#Preview {
    ChatView()
}
