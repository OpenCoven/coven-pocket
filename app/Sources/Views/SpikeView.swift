import SwiftUI

/// M1 provider surface: Anthropic API key entry, Codex OAuth sign-in, model
/// picker per provider, and effort control — all wired through the Rust
/// engine end-to-end with a streamed completion.
struct SpikeView: View {
    private static let effortLevels: [(id: String, label: String)] = [
        ("low", "○ Low"),
        ("medium", "◐ Medium"),
        ("high", "● High"),
        ("max", "◉ Max")
    ]

    @StateObject private var client = EngineClient()
    @State private var provider: PocketProvider = .anthropic
    @State private var apiKey: String = Keychain.get("anthropic-api-key") ?? ""
    @State private var anthropicModel: String = ""
    @State private var codexModel: String = ""
    @State private var effort: String = "medium"
    @State private var prompt: String = "Say hello from the coven-code engine."

    private var model: String {
        provider == .anthropic ? anthropicModel : codexModel
    }

    private var canSend: Bool {
        guard !client.isStreaming, !model.isEmpty else { return false }
        switch provider {
        case .anthropic: return !apiKey.isEmpty
        case .codex: return client.codexAccount != nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                promptSection

                if let error = client.errorMessage {
                    Section("Error") {
                        Text(error).foregroundStyle(.red)
                    }
                }

                if !client.transcript.isEmpty {
                    Section("Response") {
                        Text(client.transcript)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Coven Pocket")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Text("engine \(client.engineVersion)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: authSheetBinding) {
                if let url = client.authURL {
                    SafariView(url: url)
                        .ignoresSafeArea()
                }
            }
        }
    }

    /// Present the browser while the login flow has a URL; dismissing the
    /// sheet by hand leaves the flow to time out server-side.
    private var authSheetBinding: Binding<Bool> {
        Binding(
            get: { client.authURL != nil },
            set: { presented in
                if !presented { client.authURL = nil }
            }
        )
    }

    private var providerSection: some View {
        Section("Provider") {
            Picker("Provider", selection: $provider) {
                Text("Anthropic").tag(PocketProvider.anthropic)
                Text("Codex").tag(PocketProvider.codex)
            }
            .pickerStyle(.segmented)

            switch provider {
            case .anthropic: anthropicRows
            case .codex: codexRows
            }

            Picker("Effort", selection: $effort) {
                ForEach(Self.effortLevels, id: \.id) { level in
                    Text(level.label).tag(level.id)
                }
            }
        }
    }

    @ViewBuilder private var anthropicRows: some View {
        SecureField("Anthropic API key", text: $apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: apiKey) { _, newValue in
                Keychain.set(newValue, for: "anthropic-api-key")
            }
        Picker("Model", selection: $anthropicModel) {
            ForEach(client.models, id: \.id) { model in
                Text(model.name).tag(model.id)
            }
        }
        .task {
            guard client.models.isEmpty, !apiKey.isEmpty else { return }
            await client.loadModels(apiKey: apiKey)
            if anthropicModel.isEmpty {
                anthropicModel = client.defaultModel
            }
        }
    }

    @ViewBuilder private var codexRows: some View {
        if let account = client.codexAccount {
            LabeledContent("Account", value: account.email ?? account.profileId)
            Picker("Model", selection: $codexModel) {
                ForEach(client.codexModels, id: \.id) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .task {
                guard client.codexModels.isEmpty else { return }
                await client.loadCodexModels()
                if codexModel.isEmpty {
                    codexModel = client.defaultCodexModel
                }
            }
            Button("Sign out", role: .destructive) {
                client.codexLogout()
            }
        } else {
            Button(client.isAuthenticating ? "Waiting for sign-in…" : "Sign in with ChatGPT") {
                Task { await client.codexLogin() }
            }
            .disabled(client.isAuthenticating)
        }
    }

    private var promptSection: some View {
        Section("Prompt") {
            TextField("Prompt", text: $prompt, axis: .vertical)
                .lineLimit(2 ... 6)
            Button(client.isStreaming ? "Streaming…" : "Send") {
                Task {
                    await client.send(
                        provider: provider,
                        apiKey: apiKey,
                        model: model,
                        prompt: prompt,
                        effort: effort
                    )
                }
            }
            .disabled(!canSend)
        }
    }
}

#Preview {
    SpikeView()
}
