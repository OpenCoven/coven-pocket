import SwiftUI

struct ChatSettingsView: View {
    @Binding var settings: ChatSettings
    @ObservedObject var client: EngineClient
    @ObservedObject var model: ChatModel
    @ObservedObject var companionModel: CompanionChatModel
    @ObservedObject var familiarModel: FamiliarSelectionModel
    let onReset: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend") {
                    if availableBackends.count > 1 {
                        Picker("Backend", selection: $settings.backend) {
                            ForEach(availableBackends, id: \.self) { backend in
                                Text(backend.label).tag(backend)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: settings.backend) { _, backend in
                            if backend == .codex, settings.model.isEmpty {
                                settings.model = client.defaultCodexModel
                            }
                            synchronizeFamiliarProfile()
                        }
                    } else {
                        LabeledContent(
                            "Backend",
                            value: availableBackends.first?.label ?? "Unavailable"
                        )
                    }

                    switch settings.backend {
                    case .companionClaude:
                        companionRows
                    case .codex:
                        codexRows
                    }
                }

                FamiliarPickerSection(
                    settings: $settings,
                    model: familiarModel,
                    profile: activeFamiliarProfile,
                    refreshContext: {
                        await refreshFamiliarContext()
                    }
                )

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
                            onReset()
                            model.reset()
                            synchronizeFamiliarProfile()
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
            .task {
                await refreshFamiliarContext()
            }
            .onChange(of: companionModel.availability) {
                normalizeBackendSelection()
                synchronizeFamiliarProfile()
            }
            .onChange(of: client.codexAccount?.profileId) {
                normalizeBackendSelection()
                synchronizeFamiliarProfile()
            }
            .onChange(of: familiarModel.selectedFamiliar?.id) { oldID, newID in
                guard oldID != newID,
                      familiarModel.activeProfile == activeFamiliarProfile
                else { return }
                synchronizeFamiliarProfile()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var availableBackends: [ChatBackend] {
        ChatBackend.available(
            companionAvailable: companionModel.isAvailable
                || (companionModel.availability == .checking
                    && settings.backend == .companionClaude),
            codexAvailable: client.codexAccount != nil
        )
    }

    private var activeFamiliarProfile: FamiliarProfileKey? {
        ChatFamiliarProfile.active(
            backend: settings.backend,
            codexProfileID: client.codexAccount?.profileId,
            companionAvailability: companionModel.availability,
            previous: familiarModel.activeProfile
        )
    }

    private func normalizeBackendSelection() {
        guard companionModel.availability != .checking else { return }
        guard !availableBackends.contains(settings.backend),
              let fallback = availableBackends.first else {
            return
        }
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

    @MainActor
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
            Task { await refreshFamiliarContext() }
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
