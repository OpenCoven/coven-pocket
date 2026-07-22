import SwiftUI

/// Dev preview surface for the diff reviewer until the chat/tool-call flow
/// becomes its real entry point: loads a sample diff, lets you review it, and
/// shows the unified patch that per-hunk acceptance would feed to apply_patch.
struct DiffDemoView: View {
    @StateObject private var model = DiffReviewModel(diffText: DiffSamples.multiFile)
    @State private var appliedPatch: String?

    var body: some View {
        NavigationStack {
            DiffReviewView(model: model) { patch in
                appliedPatch = patch
            }
        }
        .sheet(isPresented: Binding(
            get: { appliedPatch != nil },
            set: { if !$0 { appliedPatch = nil } }
        )) {
            if let appliedPatch {
                PatchPreviewSheet(patch: appliedPatch)
            }
        }
    }
}

/// Shows the accepted-hunks patch exactly as it would be handed to the engine.
private struct PatchPreviewSheet: View {
    let patch: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(patch)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Accepted Patch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: patch)
                }
            }
        }
    }
}

#Preview {
    DiffDemoView()
}
