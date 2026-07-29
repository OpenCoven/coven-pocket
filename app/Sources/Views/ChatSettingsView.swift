import SwiftUI

struct ChatSettingsView: View {
    @Binding var settings: ChatSettings
    @ObservedObject var client: EngineClient
    @ObservedObject var model: ChatModel
    @ObservedObject var companionModel: CompanionChatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend") {
                    Picker("Backend", selection: $settings.backend) {
                        if companionModel.isAvailable || settings.backend == .companionClaude {
                            Text(ChatBackend.companionClaude.label)
                                .tag(ChatBackend.companionClaude)
                        }
                        if client.codexAccount != nil || settings.backend == .codex {
                            Text(ChatBackend.codex.label)
                                .tag(ChatBackend.codex)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.backend) { _, backend in
                        if backend == .codex, settings.model.isEmpty {
                            settings.model = client.defaultCodexModel
                        }
                    }

                    switch settings.backend {
                    case .companionClaude:
                        companionRows
                    case .codex:
                        codexRows
                    }
                }

                if settings.backend == .codex {
                    Section {
                        Toggle("Inject project memory", isOn: Binding(
                            get: { model.injectContext },
                            set: { model.injectContext = $0 }
                        ))
                        NavigationLink("Manage memory notes") {
                            MemoryView(
                                engine: model.engine,
                                workspacePath: model.effectiveWorkspaceURL.path
                            )
                        }
                    } header: {
                        Text("Memory")
                    } footer: {
                        Text(
                            "When on, new sessions read the workspace's AGENTS.md "
                                + "files and memory notes into the system prompt. "
                                + "Applies per workspace, from the next session."
                        )
                    }

                    Section {
                        Button("Clear conversation", role: .destructive) {
                            model.reset()
                            dismiss()
                        }
                    } footer: {
                        Text(
                            "Codex works inside the selected on-device workspace. "
                                + "Changing settings starts a new conversation; "
                                + "the permission mode (shield menu) applies live."
                        )
                    }
                }
            }
            .navigationTitle("Chat Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private var companionRows: some View {
        TextField("Project path on daemon host", text: $settings.daemonProjectRoot)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: settings.daemonProjectRoot) { _, value in
                UserDefaults.standard.set(value, forKey: "daemon-chat-project-root")
            }

        switch companionModel.availability {
        case .checking:
            Label("Checking the daemon…", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case let .ready(pairing):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daemon verified")
                    Text("\(pairing.host):\(pairing.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        case let .blocked(reason, hint):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reason)
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }

        Button("Verify daemon") {
            Task { await companionModel.refreshAvailability() }
        }

        Button("Open Companion") {
            AppRouter.shared.selectedTab = .companion
            dismiss()
        }
    }

    @ViewBuilder private var codexRows: some View {
        if let account = client.codexAccount {
            LabeledContent("Account", value: account.email ?? account.profileId)
            Picker("Model", selection: $settings.model) {
                if client.codexModels.isEmpty {
                    Text(settings.model).tag(settings.model)
                }
                ForEach(client.codexModels, id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
            .task {
                guard client.codexModels.isEmpty else { return }
                await client.loadCodexModels()
            }
        } else {
            Text("Sign in with ChatGPT from the Playground tab first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
