import SwiftUI

/// Companion mode: connect to a Coven daemon running on a Mac or server.
/// This milestone covers connection config and a reachability probe;
/// pairing and session attach build on it next.
struct CompanionView: View {
    @StateObject private var model = CompanionModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Host (Tailscale name, IP, or localhost)", text: $model.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $model.portText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Daemon address")
                } footer: {
                    Text(
                        "The daemon listens on loopback only. Reach it over your "
                            + "Tailscale network, or forward it with\n"
                            + "ssh -L 7777:localhost:7777 <your-mac>"
                    )
                }

                Section {
                    Button {
                        Task { await model.probe() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if model.status == .probing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!model.canProbe)

                    statusRow
                }

                Section {
                    Label(
                        "Pairing and live session attach arrive in a later build. "
                            + "This screen only verifies the daemon is reachable.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Companion")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .probing:
            Label("Probing…", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case let .reachable(pid, latencyMs):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daemon reachable")
                        .font(.headline)
                    Text("pid \(pid) · \(latencyMs) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case let .failed(reason, hint):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reason)
                        .font(.headline)
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}
