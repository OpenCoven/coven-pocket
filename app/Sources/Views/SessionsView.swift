import SwiftUI

/// Browser for stored chat sessions: tap to resume, swipe to delete (with
/// confirmation), context menu to fork a copy at the session's head.
struct SessionsView: View {
    @ObservedObject var model: ChatModel
    let settings: ChatSettings
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [ChatSessionSummary] = []
    @State private var pendingDelete: ChatSessionSummary?

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No saved sessions",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Conversations are saved automatically as you chat.")
                    )
                } else {
                    sessionList
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { sessions = model.storedSessions() }
            .confirmationDialog(
                "Delete this session?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { summary in
                Button("Delete \"\(summary.displayTitle)\"", role: .destructive) {
                    model.deleteSession(summary)
                    sessions = model.storedSessions()
                }
            } message: { _ in
                Text("The transcript is removed from this device.")
            }
        }
    }

    private var sessionList: some View {
        List {
            ForEach(sessions) { summary in
                Button {
                    Task {
                        await model.resume(summary, settings: settings)
                        dismiss()
                    }
                } label: {
                    SessionRow(summary: summary)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .contextMenu {
                    Button {
                        Task {
                            if await model.forkSession(summary) {
                                sessions = model.storedSessions()
                            }
                        }
                    } label: {
                        Label("Fork", systemImage: "arrow.branch")
                    }
                    Button(role: .destructive) {
                        pendingDelete = summary
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = summary
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

private struct SessionRow: View {
    let summary: ChatSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                if let date = summary.updatedDate {
                    Text(date, format: .relative(presentation: .named))
                }
                Text("·")
                Text("\(summary.messageCount) messages")
                if !summary.model.isEmpty {
                    Text("·")
                    Text(summary.model)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
