import SwiftUI

/// Identity confirmation step of the pairing flow: the handshake succeeded,
/// now the user confirms this is their machine before anything persists.
struct PairingSheet: View {
    @ObservedObject var model: CompanionModel
    let identity: DaemonIdentity

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("Address", "\(model.trimmedHost):\(model.portText)")
                    row("Protocol", identity.apiVersion)
                    row("Coven version", identity.covenVersion)
                    row("Process", "pid \(identity.pid)")
                    if !identity.startedAt.isEmpty {
                        row("Started", identity.startedAt)
                    }
                } header: {
                    Text("Daemon identity")
                } footer: {
                    Text(
                        "Confirm this matches the daemon on your machine "
                            + "(coven daemon status shows its pid)."
                    )
                }

                Section {
                    Button {
                        model.confirmPairing()
                    } label: {
                        Label("Confirm pairing", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("Confirm pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelPairing() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.callout.monospaced())
        }
    }
}
