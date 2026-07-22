import SwiftUI

struct ChatSettingsView: View {
    @Binding var settings: ChatSettings
    @ObservedObject var client: EngineClient
    @ObservedObject var model: ChatModel
    @Environment(\.dismiss) private var dismiss

    private static let effortLevels: [(id: String, label: String)] = [
        ("low", "○ Low"),
        ("medium", "◐ Medium"),
        ("high", "● High"),
        ("max", "◉ Max")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Provider", selection: $settings.provider) {
                        Text("Anthropic").tag(PocketProvider.anthropic)
                        Text("Codex").tag(PocketProvider.codex)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.provider) { _, newValue in
                        settings.model = newValue == .anthropic
                            ? client.defaultModel
                            : client.defaultCodexModel
                    }

                    switch settings.provider {
                    case .anthropic: anthropicRows
                    case .codex: codexRows
                    }

                    Picker("Effort", selection: $settings.effort) {
                        ForEach(Self.effortLevels, id: \.id) { level in
                            Text(level.label).tag(level.id)
                        }
                    }
                }

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
                        "The agent works inside Documents/workspace. "
                            + "Changing settings starts a new conversation; "
                            + "the permission mode (shield menu) applies live."
                    )
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

    @ViewBuilder private var anthropicRows: some View {
        SecureField("Anthropic API key", text: $settings.apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: settings.apiKey) { _, newValue in
                Keychain.set(newValue, for: "anthropic-api-key")
            }
        Picker("Model", selection: $settings.model) {
            if client.models.isEmpty {
                Text(settings.model).tag(settings.model)
            }
            ForEach(client.models, id: \.id) { entry in
                Text(entry.name).tag(entry.id)
            }
        }
        .task(id: settings.apiKey) {
            guard !settings.apiKey.isEmpty, client.models.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await client.loadModels(apiKey: settings.apiKey)
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
