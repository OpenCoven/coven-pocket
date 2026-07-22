import SwiftUI

/// Sessions running on the paired daemon; tap one to attach.
struct RemoteSessionsView: View {
    @StateObject private var model: RemoteSessionsModel

    init(companion: CompanionModel) {
        _model = StateObject(wrappedValue: RemoteSessionsModel(companion: companion))
    }

    var body: some View {
        List {
            content
        }
        .navigationTitle("Remote sessions")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            HStack {
                ProgressView()
                Text("Checking the daemon…")
                    .foregroundStyle(.secondary)
            }
        case let .blocked(reason, hint):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reason).font(.headline)
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        case .loaded where model.sessions.isEmpty:
            Text("No sessions on this daemon yet. Start one with coven run.")
                .foregroundStyle(.secondary)
        case .loaded:
            ForEach(model.sessions, id: \.id) { session in
                if let pairing = model.companion.pairing {
                    NavigationLink {
                        RemoteSessionView(
                            session: session, pairing: pairing,
                            engine: model.companion.engine
                        )
                    } label: {
                        row(session)
                    }
                }
            }
        }
    }

    private func row(_ session: RemoteSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title.isEmpty ? session.id : session.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                statusBadge(session.status)
                Text(session.harness)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.projectRoot)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                status == "running" ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(status == "running" ? .green : .secondary)
    }
}
