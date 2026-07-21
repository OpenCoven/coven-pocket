import SwiftUI

/// M0 spike screen: prove key entry, model listing, and a streamed
/// completion through the Rust engine end-to-end.
struct SpikeView: View {
    @StateObject private var client = EngineClient()
    @State private var apiKey: String = Keychain.get("anthropic-api-key") ?? ""
    @State private var model: String = ""
    @State private var prompt: String = "Say hello from the coven-code engine."

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    SecureField("Anthropic API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: apiKey) { _, newValue in
                            Keychain.set(newValue, for: "anthropic-api-key")
                        }
                    Picker("Model", selection: $model) {
                        ForEach(client.models, id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .task {
                        guard client.models.isEmpty else { return }
                        await client.loadModels(apiKey: apiKey)
                        if model.isEmpty {
                            model = client.defaultModel
                        }
                    }
                }

                Section("Prompt") {
                    TextField("Prompt", text: $prompt, axis: .vertical)
                        .lineLimit(2 ... 6)
                    Button(client.isStreaming ? "Streaming…" : "Send") {
                        Task {
                            await client.send(apiKey: apiKey, model: model, prompt: prompt)
                        }
                    }
                    .disabled(client.isStreaming || apiKey.isEmpty || model.isEmpty)
                }

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
        }
    }
}

#Preview {
    SpikeView()
}
