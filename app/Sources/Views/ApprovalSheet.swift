import SwiftUI

/// Approval sheet for one gated write: what tool, which files, and a preview
/// of the proposed change. Swiping the sheet away denies the call.
struct ApprovalSheet: View {
    let approval: PendingApproval
    @ObservedObject var model: ChatModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Tool", value: approval.request.toolName)
                    if !approval.request.paths.isEmpty {
                        LabeledContent("Files") {
                            Text(approval.request.paths)
                                .font(.callout.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                if !approval.request.preview.isEmpty {
                    Section("Proposed change") {
                        ScrollView(.horizontal) {
                            Text(approval.request.preview)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                Section {
                    Button("Allow once") {
                        model.respond(to: approval, decision: .allow)
                    }
                    Button("Allow \(approval.request.toolName) for this session") {
                        model.respond(to: approval, decision: .allowSession)
                    }
                    Button("Deny", role: .destructive) {
                        model.respond(to: approval, decision: .deny)
                    }
                }
            }
            .navigationTitle("Approve edit?")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
