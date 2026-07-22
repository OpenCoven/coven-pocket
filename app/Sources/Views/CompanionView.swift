import SwiftUI

/// Companion mode: connect to and pair with a Coven daemon on a Mac or
/// server. Pairing requires the coven.daemon.v1 handshake; session traffic
/// in later milestones gates on the stored pairing.
struct CompanionView: View {
    @StateObject private var model = CompanionModel()
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                if let pairing = model.pairing {
                    pairedSections(pairing)
                } else {
                    unpairedSections
                }
            }
            .navigationTitle("Companion")
            .sheet(
                isPresented: Binding(
                    get: { model.pendingIdentity != nil },
                    set: { if !$0 { model.cancelPairing() } }
                )
            ) {
                if let identity = model.pendingIdentity {
                    PairingSheet(model: model, identity: identity)
                }
            }
            .confirmationDialog(
                "Unpair from this daemon?",
                isPresented: $confirmingUnpair,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) { model.unpair() }
            } message: {
                Text("Session features will be unavailable until you pair again.")
            }
        }
    }

    // MARK: - Unpaired

    @ViewBuilder
    private var unpairedSections: some View {
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

            Button {
                Task { await model.beginPairing() }
            } label: {
                Label("Pair with daemon", systemImage: "link.badge.plus")
            }
            .disabled(!model.canProbe)

            statusRow
        } footer: {
            Text(
                "Pairing runs the coven.daemon.v1 handshake and stores the "
                    + "daemon's identity in your Keychain."
            )
        }
    }

    // MARK: - Paired

    @ViewBuilder
    private func pairedSections(_ pairing: DaemonPairing) -> some View {
        Section {
            LabeledContent("Address", value: "\(pairing.host):\(pairing.port)")
            LabeledContent("Protocol", value: pairing.apiVersion)
            LabeledContent("Coven version", value: pairing.covenVersion)
            LabeledContent("Process", value: "pid \(pairing.pid)")
            LabeledContent("Paired", value: pairing.pairedAt.formatted(
                date: .abbreviated, time: .shortened
            ))
        } header: {
            Label("Paired daemon", systemImage: "link")
        }

        Section {
            NavigationLink {
                RemoteSessionsView(companion: model)
            } label: {
                Label("Remote sessions", systemImage: "rectangle.connected.to.line.below")
            }
        } footer: {
            Text("Attach to sessions running on the paired daemon.")
        }

        Section {
            Button {
                Task { await model.verifyPairing() }
            } label: {
                HStack {
                    Text("Verify connection")
                    Spacer()
                    if model.status == .probing {
                        ProgressView()
                    }
                }
            }
            .disabled(model.status == .probing)

            statusRow

            Button("Unpair", role: .destructive) {
                confirmingUnpair = true
            }
        } footer: {
            Text("To pair with a different daemon, unpair first.")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .probing:
            Label("Probing…", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case let .reachable(pid, latencyMs):
            statusLabel(
                "Daemon reachable", detail: "pid \(pid) · \(latencyMs) ms",
                icon: "checkmark.circle.fill", tint: .green
            )
        case .verified:
            statusLabel(
                "Pairing verified", detail: "coven.daemon.v1 handshake succeeded",
                icon: "checkmark.seal.fill", tint: .green
            )
        case let .failed(reason, hint):
            statusLabel(reason, detail: hint, icon: "xmark.octagon.fill", tint: .red)
        }
    }

    private func statusLabel(
        _ title: String, detail: String, icon: String, tint: Color
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
    }
}
