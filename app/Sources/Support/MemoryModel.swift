import Foundation

/// Browser state for the active workspace's memory notes, plus a preview of
/// the composed context a session would inject. All engine calls are async;
/// results land back on the main actor.
@MainActor
final class MemoryModel: ObservableObject {
    @Published var notes: [MemoryNote] = []
    @Published var contextPreview: ProjectContext?
    @Published var errorText: String?

    private let engine: PocketEngine
    let workspacePath: String

    init(engine: PocketEngine, workspacePath: String) {
        self.engine = engine
        self.workspacePath = workspacePath
    }

    /// Reload the note list and the context preview together so the header
    /// never disagrees with the rows below it.
    func refresh() async {
        do {
            notes = try await engine.listMemoryNotes(workspaceDir: workspacePath)
            contextPreview = try await engine.projectContext(workspaceDir: workspacePath)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func read(filename: String) async -> String? {
        do {
            return try await engine.readMemoryNote(
                workspaceDir: workspacePath, filename: filename
            )
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }

    /// Create or overwrite a note, then refresh so the list reflects it.
    func save(filename: String, content: String) async {
        do {
            try await engine.writeMemoryNote(
                workspaceDir: workspacePath, filename: filename, content: content
            )
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func delete(filename: String) async {
        do {
            try await engine.deleteMemoryNote(
                workspaceDir: workspacePath, filename: filename
            )
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

extension MemoryNote {
    /// Frontmatter name when present, else the filename.
    var displayName: String {
        name.isEmpty ? filename : name
    }

    var modifiedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(modifiedSecs))
    }
}
