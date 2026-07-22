import SwiftUI

/// Live attachment to one remote session: transcript, input forwarding,
/// and one-tap approval when the harness asks for permission.
struct RemoteSessionView: View {
    @StateObject private var model: RemoteAttachModel

    init(session: RemoteSession, pairing: DaemonPairing, engine: PocketEngine) {
        _model = StateObject(
            wrappedValue: RemoteAttachModel(session: session, pairing: pairing, engine: engine)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let prompt = model.approvalPrompt {
                approvalBar(prompt)
            }
            if let error = model.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
            inputBar
        }
        .navigationTitle(model.session.title.isEmpty ? "Session" : model.session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        Task { await model.kill() }
                    } label: {
                        Label("Kill session", systemImage: "stop.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await model.attach() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.items) { item in
                        RemoteTranscriptRow(item: item)
                            .id(item.id)
                    }
                    if model.finished {
                        Label("Session finished", systemImage: "flag.checkered")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .onChange(of: model.items.last?.id) { _, lastId in
                if let lastId {
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
        }
    }

    private func approvalBar(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(prompt, systemImage: "hand.raised.fill")
                .font(.footnote)
                .lineLimit(2)
            HStack {
                Button {
                    Task { await model.approve() }
                } label: {
                    Label("Approve", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                    Task { await model.deny() }
                } label: {
                    Label("Deny", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.yellow.opacity(0.12))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Send to session…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(model.finished)
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(
                model.finished
                    || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(12)
        .background(.bar)
    }
}

/// One transcript row, styled by role.
struct RemoteTranscriptRow: View {
    let item: RemoteTranscriptItem

    var body: some View {
        switch item.role {
        case .user:
            Text(item.text)
                .padding(10)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Text(item.text)
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .tool(isError):
            Label {
                Text(item.text)
                    .font(.caption.monospaced())
                    .lineLimit(6)
            } icon: {
                Image(systemName: isError ? "wrench.adjustable" : "wrench.and.screwdriver")
                    .foregroundStyle(isError ? .red : .secondary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .terminal:
            Text(item.text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.green)
        case .status:
            Text(item.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}
