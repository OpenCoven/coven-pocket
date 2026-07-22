import SwiftUI

/// Share the current chat as an unlisted GitHub Gist: redacted preview,
/// one-tap upload, link copy, and revocation of earlier shares.
struct ShareSessionSheet: View {
    let items: [ChatItem]

    @StateObject private var model = GistShareModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                redactionSection
                previewSection
                tokenSection
                actionSection
                pastSharesSection
            }
            .navigationTitle("Share session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.prepare(items: items) }
        }
    }

    private var redactionSection: some View {
        Section {
            if model.phase == .preparing {
                Label("Scanning for secrets…", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
            } else if model.findings.isEmpty {
                Label("No secrets detected", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
            } else {
                ForEach(model.findings, id: \.label) { finding in
                    Label(
                        "\(finding.label) ×\(finding.count) redacted",
                        systemImage: "eye.slash"
                    )
                    .foregroundStyle(.orange)
                }
            }
        } footer: {
            Text("Only the redacted text below ever leaves this device.")
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            ScrollView {
                Text(model.preview.isEmpty ? " " : model.preview)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }

    @ViewBuilder
    private var tokenSection: some View {
        Section {
            SecureField("GitHub token (gist scope)", text: $model.token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } footer: {
            Text("Stored in the Keychain. Needs only the gist scope.")
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            switch model.phase {
            case .preparing, .ready:
                Button {
                    Task { await model.upload() }
                } label: {
                    Label("Create unlisted gist", systemImage: "square.and.arrow.up")
                }
                .disabled(model.phase != .ready || model.token.isEmpty)
            case .uploading:
                HStack {
                    ProgressView()
                    Text("Uploading…").foregroundStyle(.secondary)
                }
            case .shared(let share):
                Link(destination: URL(string: share.url) ?? Self.gistsHome) {
                    Label(share.url, systemImage: "link")
                        .lineLimit(1)
                }
                Button {
                    UIPasteboard.general.string = share.url
                } label: {
                    Label("Copy link", systemImage: "doc.on.doc")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Try again") { model.resetToReady() }
            }
        } footer: {
            Text("Unlisted gists are hidden from search but visible to anyone with the link.")
        }
    }

    @ViewBuilder
    private var pastSharesSection: some View {
        if !model.pastShares.isEmpty {
            Section("Shared from this device") {
                ForEach(model.pastShares) { share in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(share.title).lineLimit(1)
                            Text(share.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.revoke(share) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Revoke \(share.title)")
                    }
                }
            }
        }
    }

    private static let gistsHome = URL(string: "https://gist.github.com")!
}
