import SwiftUI

// swiftlint:disable file_length

/// Multi-turn chat through either a verified companion daemon's Claude CLI
/// or the on-device Codex engine.
struct ChatView: View {
    @StateObject private var model = ChatModel()
    @StateObject private var client = EngineClient()
    @StateObject private var companion: CompanionModel
    @StateObject private var companionModel: CompanionChatModel
    @StateObject private var familiarModel: FamiliarSelectionModel
    @StateObject private var routeCoordinator = ChatRouteGenerationCoordinator()
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

    init() {
        let sharedCompanion = CompanionModel()
        _companion = StateObject(wrappedValue: sharedCompanion)
        _companionModel = StateObject(wrappedValue: CompanionChatModel(companion: sharedCompanion))
        _familiarModel = StateObject(wrappedValue: FamiliarSelectionModel(companion: sharedCompanion))
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
            .onChange(of: client.codexAccount?.profileId) {
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
    var activeFamiliarProfile: FamiliarProfileKey? {
        ChatFamiliarProfile.active(
            backend: settings.backend,
            codexProfileID: client.codexAccount?.profileId,
            companionAvailability: companionModel.availability,
            previous: familiarModel.activeProfile
        )
    }

    var routedSettings: Binding<ChatSettings> {
        Binding(
            get: { settings },
            set: { updated in
                if updated.backend != settings.backend {
                    routeCoordinator.invalidate()
                }
                settings = updated
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
    private func consumeRouterPrompt() async {
        guard let queued = router.consumePrompt() else { return }
        prompt = queued
        guard canSend else { return }
        prompt = ""
        startSend(queued)
    }

    /// Spotlight indexes on-device sessions, so this explicit history choice
    /// switches to Codex rather than acting as an error fallback.
    private func consumeRouterSession() async {
        guard let sessionID = router.consumeSessionID() else { return }
        let token = routeCoordinator.begin()
        guard let currentSettings = ChatFamiliarProfile.settingsForCodexResume(
            current: settings,
            codexProfileID: client.codexAccount?.profileId,
            defaultModel: client.defaultCodexModel,
            model: familiarModel
        ) else {
            routeCoordinator.retire(token)
            return
        }
        settings = currentSettings
        Task {
            await SpotlightSessionRouteRunner.run(
                token: token,
                coordinator: routeCoordinator,
                lookup: {
                    await model.storedSessions()
                        .first(where: { $0.sessionId == sessionID })
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
            await model.send(
                prompt: text,
                settings: settings,
                selectedFamiliar: familiarModel.selectedFamiliar
            )
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
        routeCoordinator.invalidate()
        switch settings.backend {
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
        settings.familiarID = ChatFamiliarProfile.synchronize(
            activeFamiliarProfile,
            model: familiarModel
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
    ChatView()
}
