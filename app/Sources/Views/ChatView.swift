import SwiftUI

// swiftlint:disable file_length

/// Multi-turn chat through either a verified companion daemon's Claude CLI
/// or the on-device Codex engine.
struct ChatView: View {
    @ObservedObject var client: EngineClient
    @ObservedObject var chatState: ChatSurfaceState
    @ObservedObject private var model: ChatModel
    @ObservedObject private var companion: CompanionModel
    @ObservedObject private var companionModel: CompanionChatModel
    @ObservedObject private var familiarModel: FamiliarSelectionModel
    private let routeCoordinator: ChatRouteGenerationCoordinator
    @ObservedObject private var router = AppRouter.shared

    @State private var prompt = ""
    @State private var showSettings = false
    @State private var showSessions = false
    @State private var showShare = false

    init(client: EngineClient, chatState: ChatSurfaceState) {
        _client = ObservedObject(wrappedValue: client)
        _chatState = ObservedObject(wrappedValue: chatState)
        _model = ObservedObject(wrappedValue: chatState.model)
        _companion = ObservedObject(wrappedValue: chatState.companion)
        _companionModel = ObservedObject(
            wrappedValue: chatState.companionModel
        )
        _familiarModel = ObservedObject(
            wrappedValue: chatState.familiarModel
        )
        routeCoordinator = chatState.routeCoordinator
    }

    private var settings: ChatSettings {
        get { chatState.settings }
        nonmutating set { chatState.settings = newValue }
    }

    private var activeItems: [ChatItem] { settings.backend == .companionClaude ? companionModel.items : model.items }

    private var activeIsBusy: Bool { settings.backend == .companionClaude ? companionModel.isBusy : model.isBusy }

    private var activeCanRetry: Bool { settings.backend == .companionClaude ? companionModel.canRetry : model.canRetry }

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
                if settings.backend == .codex, let goal = model.goal {
                    goalCard(goal)
                    Divider()
                }
                transcript
                Divider()
                inputBar
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if let identitySeal {
                        FamiliarIdentitySeal(value: identitySeal)
                    }
                    if settings.backend == .codex {
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
                        routeCoordinator.invalidate()
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
                    settings: routedSettings,
                    client: client,
                    model: model,
                    companionModel: companionModel,
                    familiarModel: familiarModel,
                    onReset: { routeCoordinator.invalidate() }
                )
            }
            .sheet(isPresented: $showSessions) {
                if settings.backend == .companionClaude {
                    NavigationStack {
                        RemoteSessionsView(
                            companion: companion,
                            showsDoneButton: true
                        )
                    }
                } else {
                    SessionsView(
                        model: model,
                        settings: settings,
                        onResume: { routeCoordinator.invalidate() }
                    )
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
                    await refreshFamiliarContext()
                }
            }
            .onChange(of: settings.backend) {
                synchronizeFamiliarProfile()
            }
            .onChange(of: companionModel.availability) {
                normalizeBackendSelection()
                synchronizeFamiliarProfile()
            }
            .onChange(of: familiarModel.selectedFamiliar?.id) { oldID, newID in
                guard oldID != newID,
                      familiarModel.activeProfile == activeFamiliarProfile
                else { return }
                synchronizeFamiliarProfile()
            }
            .task(id: router.pendingPrompt) { consumeRouterPrompt() }
            .task(id: router.pendingSessionID) { consumeRouterSession() }
            .task(id: router.pendingReset) {
                consumeRouterReset()
            }
        }
    }
}

extension ChatView {
    static func spotlightSession(
        sessionID: String,
        loader: SessionListModel.Loader
    ) async -> ChatSessionSummary? {
        do {
            let sessions = try await loader()
            return sessions.first { $0.sessionId == sessionID }
        } catch {
            return nil
        }
    }

    static func consumeQueuedPrompt(
        _ queued: String?,
        coordinator: ChatRouteGenerationCoordinator,
        stage: (String) -> Void,
        canSend: () -> Bool
    ) -> String? {
        guard let queued else { return nil }
        coordinator.invalidate()
        stage(queued)
        return canSend() ? queued : nil
    }
}

private extension ChatView {
    @ViewBuilder
    func goalCard(_ goal: GoalSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: goal.status == .active ? "target" : "pause.circle")
                .foregroundStyle(goal.status == .active ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.status == .active ? "Goal in progress" : "Goal \(goalStatusLabel(goal.status))")
                    .font(.subheadline.weight(.semibold))
                Text("Turn \(goal.turnsUsed)/\(goal.maxTurns) · \(goal.tokensUsed) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if goal.status == .active {
                Button("Pause") { Task { await model.pauseGoal() } }
            } else if goal.status == .paused {
                Button("Resume") { Task { await model.resumeGoal() } }
            }
            Button("Clear", role: .destructive) { Task { await model.clearGoal() } }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Goal \(goalStatusLabel(goal.status)), turn \(goal.turnsUsed) of \(goal.maxTurns), "
                + "\(goal.tokensUsed) tokens"
        )
    }

    func goalStatusLabel(_ status: PocketGoalStatus) -> String {
        switch status {
        case .active: "in progress"
        case .paused: "paused"
        case .budgetLimited: "budget limited"
        case .complete: "complete"
        }
    }

    var activeFamiliarProfile: FamiliarProfileKey? {
        chatState.activeFamiliarProfile(
            codexProfileID: client.codexAccount?.profileId
        )
    }

    var routedSettings: Binding<ChatSettings> {
        Binding(
            get: { settings },
            set: { updated in
                if updated.backend != settings.backend {
                    routeCoordinator.invalidate()
                }
                chatState.settings = updated
            }
        )
    }

    var identitySeal: FamiliarSealValue? {
        switch settings.backend {
        case .companionClaude:
            return FamiliarSealResolver.companion(
                activeFamiliar: companionModel.sessionFamiliar,
                hasActiveSession: companionModel.hasActiveSession,
                selectedFamiliar: familiarModel.selectedFamiliar,
                roster: familiarModel.roster
            )
        case .codex:
            return FamiliarSealResolver.onDevice(
                activeFamiliar: model.activeFamiliar,
                hasActiveSession: model.hasActiveSession,
                selectedFamiliar: familiarModel.selectedFamiliar,
                roster: familiarModel.roster
            )
        }
    }

    // MARK: - Intent / Spotlight handoff

    /// Send a queued intent when configured; the nested task survives
    /// cancellation caused by consuming the router value.
    private func consumeRouterPrompt() {
        consumePendingRouterReset()
        guard let queued = router.consumePrompt() else { return }
        let token = routeCoordinator.begin()
        Task { @MainActor in
            await routeCoordinator.runAfterRoutedReset(token: token) {
                guard let queuedForSend = Self.consumeQueuedPrompt(
                    queued,
                    coordinator: routeCoordinator,
                    stage: { prompt = $0 },
                    canSend: { canSend }
                ) else { return }
                prompt = ""
                startSend(queuedForSend)
            }
        }
    }

    /// Spotlight indexes on-device sessions, so this explicit history choice
    /// switches to Codex rather than acting as an error fallback.
    private func consumeRouterSession() {
        consumePendingRouterReset()
        guard let sessionID = router.consumeSessionID() else { return }
        let token = routeCoordinator.begin()
        Task { @MainActor in
            await routeCoordinator.runAfterRoutedReset(
                token: token,
                canProceed: { !companionModel.hasPendingCleanup },
                operation: {
                    guard let currentSettings =
                            ChatFamiliarProfile.settingsForCodexResume(
                                current: settings,
                                codexProfileID: client.codexAccount?.profileId,
                                defaultModel: client.defaultCodexModel,
                                model: familiarModel
                            ) else {
                        routeCoordinator.retire(token)
                        return
                    }
                    chatState.settings = currentSettings
                    await SpotlightSessionRouteRunner.run(
                        token: token,
                        coordinator: routeCoordinator,
                        lookup: {
                            await ChatView.spotlightSession(
                                sessionID: sessionID,
                                loader: { try await model.storedSessions() }
                            )
                        },
                        cancelResume: {
                            model.stop()
                        },
                        resume: { summary in
                            _ = await model.resume(
                                summary,
                                settings: currentSettings
                            )
                        }
                    )
                }
            )
        }
    }

    private func consumeRouterReset() {
        guard router.consumeReset() else { return }
        let backend = settings.backend
        routeCoordinator.launchRoutedReset(for: backend) {
            await resetActiveConversation(backend: backend)
        }
    }

    private func consumePendingRouterReset() {
        guard router.pendingReset else { return }
        consumeRouterReset()
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
                    startSend(text)
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

    private func startSend(_ text: String) {
        routeCoordinator.invalidate()
        Task { await send(text) }
    }

    private func send(_ text: String) async {
        switch settings.backend {
        case .companionClaude:
            await companionModel.send(
                prompt: text,
                projectRoot: settings.daemonProjectRoot,
                familiarID: settings.familiarID,
                familiar: familiarModel.selectedFamiliar,
                familiarProfile: familiarModel.activeProfile
            )
        case .codex:
            switch GoalCommandParser.parse(text) {
            case .notGoal:
                await model.send(
                    prompt: text,
                    settings: settings,
                    selectedFamiliar: familiarModel.selectedFamiliar
                )
            case let .command(.start(objective, tokenBudget)):
                await model.startGoal(
                    objective: objective,
                    tokenBudget: tokenBudget,
                    settings: settings,
                    selectedFamiliar: familiarModel.selectedFamiliar
                )
            case .command(.status):
                if model.goal == nil { await model.loadGoalStatus() }
            case .command(.pause):
                await model.pauseGoal()
            case .command(.resume):
                await model.resumeGoal()
            case .command(.clear):
                await model.clearGoal()
            case let .error(message):
                model.appendError(message)
            }
        }
    }

    private func retryActiveConversation() async {
        switch settings.backend {
        case .companionClaude:
            await companionModel.retry {
                CompanionPromptRetrySelection(
                    familiarID: settings.familiarID,
                    familiar: familiarModel.selectedFamiliar,
                    profile: familiarModel.activeProfile
                )
            }
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

    private func resetActiveConversation(backend: ChatBackend) async {
        switch backend {
        case .companionClaude:
            await companionModel.reset()
        case .codex:
            model.reset()
        }
        synchronizeFamiliarProfile()
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
        routeCoordinator.invalidate()
        settings.backend = fallback
        if fallback == .codex, settings.model.isEmpty {
            settings.model = client.defaultCodexModel
        }
    }

    private func synchronizeFamiliarProfile() {
        chatState.synchronizeFamiliarProfile(
            codexProfileID: client.codexAccount?.profileId
        )
    }

    private func refreshFamiliarContext() async {
        await FamiliarContextRefreshCoordinator.refresh(
            availability: {
                await companionModel.refreshAvailability()
            },
            synchronizeAfterAvailability: {
                normalizeBackendSelection()
                synchronizeFamiliarProfile()
            },
            roster: {
                await familiarModel.refresh()
            },
            synchronizeAfterRoster: {
                synchronizeFamiliarProfile()
            }
        )
    }
}
#Preview {
    ChatView(
        client: EngineClient(),
        chatState: ChatSurfaceState()
    )
}
