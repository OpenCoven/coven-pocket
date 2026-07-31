import SwiftUI

/// Browser for stored chat sessions: tap to resume, swipe to delete (with
/// confirmation), context menu to fork a copy at the session's head.
struct SessionsView: View {
    @ObservedObject var model: ChatModel
    let settings: ChatSettings
    let onResume: () -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var sessions: ModalSessionsModel
    @State private var pendingDelete: ChatSessionSummary?

    init(
        model: ChatModel,
        settings: ChatSettings,
        onResume: @escaping () -> Void
    ) {
        self.model = model
        self.settings = settings
        self.onResume = onResume
        _sessions = StateObject(
            wrappedValue: ModalSessionsModel(chatModel: model)
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.summaries.isEmpty {
                    emptyState
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
            .task { await sessions.refresh() }
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
                    Task { await sessions.delete(summary) }
                }
                .disabled(sessions.isMutating)
            } message: { _ in
                Text("The transcript is removed from this device.")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch sessions.loadState {
        case .idle, .loading:
            ProgressView("Loading sessions")
        case .failed:
            VStack(spacing: 0) {
                ContentUnavailableView {
                    Label(
                        "Unable to load sessions",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text("Your saved sessions are still on this device.")
                } actions: {
                    Button("Retry") {
                        Task { await sessions.refresh() }
                    }
                    .accessibilityHint("Attempts to reload saved sessions.")
                }
                emptyOperationError
            }
        case .loaded:
            VStack(spacing: 0) {
                ContentUnavailableView(
                    "No saved sessions",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        "Conversations are saved automatically as you chat."
                    )
                )
                emptyOperationError
            }
        }
    }

    @ViewBuilder
    private var emptyOperationError: some View {
        if let error = sessions.operationError {
            SessionListErrorRow(error: error) {
                Task { await sessions.refresh() }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private var sessionList: some View {
        List {
            ForEach(sessions.errors, id: \.self) { error in
                SessionListErrorRow(error: error) {
                    Task { await sessions.refresh() }
                }
            }
            ForEach(sessions.summaries) { summary in
                Button {
                    onResume()
                    Task {
                        if await model.resume(
                            summary,
                            settings: settings
                        ) {
                            dismiss()
                        }
                    }
                } label: {
                    SessionRow(summary: summary)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .contextMenu {
                    Button {
                        Task { await sessions.fork(summary) }
                    } label: {
                        Label("Fork", systemImage: "arrow.branch")
                    }
                    .disabled(sessions.isMutating)
                    Button(role: .destructive) {
                        pendingDelete = summary
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(
                        sessions.isMutating ||
                            !model.canDeleteSession(summary)
                    )
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = summary
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(
                        sessions.isMutating ||
                            !model.canDeleteSession(summary)
                    )
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await sessions.refresh() }
    }
}

struct SessionListErrorRow: View {
    let error: SessionListModel.ErrorState
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if error.allowsRetry {
                Button("Retry", action: retry)
                    .accessibilityHint("Attempts to reload saved sessions.")
            }
        }
        .accessibilityElement(children: .contain)
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
