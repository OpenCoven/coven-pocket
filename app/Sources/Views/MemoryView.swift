import SwiftUI

/// Browser for the workspace's memory notes: what the agent will remember
/// across sessions when context injection is on. Notes live in the app's
/// per-project memory directory, not in the workspace itself.
struct MemoryView: View {
    @StateObject private var model: MemoryModel
    @State private var editor: EditorState?

    init(engine: PocketEngine, workspacePath: String) {
        _model = StateObject(
            wrappedValue: MemoryModel(engine: engine, workspacePath: workspacePath)
        )
    }

    var body: some View {
        List {
            if let context = model.contextPreview {
                contextSection(context)
            }
            notesSection
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = EditorState(filename: "", content: "", isNew: true)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New note")
            }
        }
        .sheet(item: $editor) { state in
            MemoryEditorSheet(model: model, state: state)
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }

    private func contextSection(_ context: ProjectContext) -> some View {
        Section {
            if context.sources.isEmpty && !context.truncated {
                Text(
                    "No project context yet. AGENTS.md files in the workspace "
                        + "and notes below are injected when the Memory toggle is on."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                ForEach(context.sources, id: \.self) { source in
                    Label(source, systemImage: "doc.text")
                        .font(.footnote)
                }
            }
            if context.truncated {
                Label("Context exceeds the size budget and was truncated.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Injected context")
        } footer: {
            if let error = model.errorText {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            if model.notes.isEmpty {
                Text("No memory notes.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.notes, id: \.filename) { note in
                Button {
                    Task {
                        if let content = await model.read(filename: note.filename) {
                            editor = EditorState(
                                filename: note.filename, content: content, isNew: false
                            )
                        }
                    }
                } label: {
                    MemoryNoteRow(note: note)
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                let filenames = offsets.map { model.notes[$0].filename }
                Task {
                    for filename in filenames {
                        await model.delete(filename: filename)
                    }
                }
            }
        }
    }
}

private struct MemoryNoteRow: View {
    let note: MemoryNote

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(note.displayName)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                if !note.noteType.isEmpty {
                    Text(note.noteType)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            if !note.description.isEmpty {
                Text(note.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(note.modifiedDate, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// Identity for the editor sheet: which note is open (or a new one).
struct EditorState: Identifiable {
    var filename: String
    var content: String
    let isNew: Bool
    var id: String { isNew ? "new" : filename }
}

private struct MemoryEditorSheet: View {
    @ObservedObject var model: MemoryModel
    @State var state: EditorState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if state.isNew {
                    Section("Filename") {
                        TextField("note-name.md", text: $state.filename)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Section("Content") {
                    TextEditor(text: $state.content)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 240)
                }
                if let error = model.errorText {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(state.isNew ? "New Note" : state.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.save(
                                filename: normalizedFilename, content: state.content
                            )
                            if model.errorText == nil { dismiss() }
                        }
                    }
                    .disabled(saveDisabled)
                }
            }
        }
    }

    /// Let users type a bare name; the memdir only holds Markdown.
    private var normalizedFilename: String {
        let trimmed = state.filename.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix(".md") ? trimmed : trimmed + ".md"
    }

    private var saveDisabled: Bool {
        state.filename.trimmingCharacters(in: .whitespaces).isEmpty
            || state.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
