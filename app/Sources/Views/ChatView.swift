import SwiftUI

/// M1 agentic chat surface: a multi-turn conversation with the on-device
/// engine, streaming text and tool-call cards, bound to the app's sandboxed
/// workspace directory.
struct ChatView: View {
    @StateObject private var model = ChatModel()
    @StateObject private var client = EngineClient()
    @ObservedObject private var router = AppRouter.shared

    @State private var settings = ChatSettings(
        apiKey: Keychain.get("anthropic-api-key") ?? ""
    )
    @State private var prompt = ""
    @State private var showSettings = false
    @State private var showSessions = false
    @State private var showShare = false

    private var canSend: Bool {
        guard !model.isBusy, !settings.model.isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        switch settings.provider {
        case .anthropic: return !settings.apiKey.isEmpty
        case .codex: return client.codexAccount != nil
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(model.items.isEmpty)
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
                ChatSettingsView(settings: $settings, client: client, model: model)
            }
            .sheet(isPresented: $showSessions) {
                SessionsView(model: model, settings: settings)
            }
            .sheet(isPresented: $showShare) {
                ShareSessionSheet(items: model.items)
            }
            .sheet(item: $model.pendingApproval, onDismiss: model.approvalDismissed) { approval in
                ApprovalSheet(approval: approval, model: model)
                    .presentationDetents([.medium, .large])
            }
            .task {
                if settings.model.isEmpty {
                    settings.model = client.defaultModel
                }
            }
            .task(id: router.pendingPrompt) { await consumeRouterPrompt() }
            .task(id: router.pendingSessionID) { await consumeRouterSession() }
            .task(id: router.pendingReset) {
                if router.consumeReset() { model.reset() }
            }
        }
    }

    // MARK: - Intent / Spotlight handoff

    /// Run a prompt queued by `AskCovenIntent`: send it when the provider is
    /// configured, otherwise leave it in the input bar for the user.
    /// Consuming clears the published value (changing the task id), so the
    /// actual work runs in a detached-lifetime `Task` that survives the
    /// resulting cancellation.
    private func consumeRouterPrompt() async {
        guard let queued = router.consumePrompt() else { return }
        prompt = queued
        guard canSend else { return }
        prompt = ""
        let settings = settings
        Task { await model.send(prompt: queued, settings: settings) }
    }

    /// Resume a stored session picked from a Spotlight result.
    private func consumeRouterSession() async {
        guard let sessionID = router.consumeSessionID() else { return }
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
                    if model.items.isEmpty {
                        emptyState
                    }
                    ForEach(model.items) { item in
                        ChatRow(item: item)
                            .id(item.id)
                    }
                    if model.canRetry {
                        Button("Retry") {
                            Task { await model.retry() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .onChange(of: model.items.last?.text) {
                if let last = model.items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agentic chat")
                .font(.headline)
            Text(
                "The agent can read, search, and edit files inside this app's "
                    + "workspace folder (visible in the Files app). Shell and "
                    + "network tools are not available on device."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $prompt, axis: .vertical)
                .lineLimit(1 ... 4)
                .textFieldStyle(.roundedBorder)

            if model.isBusy {
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .accessibilityLabel("Stop")
            } else {
                Button {
                    let text = prompt
                    prompt = ""
                    Task { await model.send(prompt: text, settings: settings) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// A single transcript row.
private struct ChatRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            Text(item.text)
                .textSelection(.enabled)
        case .thinking:
            DisclosureGroup("Thinking") {
                Text(item.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .status:
            Text(item.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        case .tool:
            if let tool = item.tool {
                ToolCallCard(tool: tool)
            }
        }
    }
}

/// Card for one tool invocation: name, target, and expandable result.
private struct ToolCallCard: View {
    let tool: ToolCallInfo
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                Text(tool.name)
                    .font(.subheadline.weight(.medium))
                if !tool.inputSummary.isEmpty {
                    Text(tool.inputSummary)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            if expanded, let result = tool.result {
                Text(result)
                    .font(.footnote.monospaced())
                    .foregroundStyle(tool.isError ? .red : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(20)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            guard tool.result != nil else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                expanded.toggle()
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if tool.isRunning {
            ProgressView()
                .controlSize(.small)
        } else if tool.isError {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

/// Provider, credential, model, and effort settings for the chat session.
/// Changing anything starts a new session (the engine conversation is bound
/// to its settings), so the transcript resets on the next send.
#Preview {
    ChatView()
}
