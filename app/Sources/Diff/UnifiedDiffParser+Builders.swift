import Foundation

// MARK: - Builders

extension UnifiedDiffParser {
    final class HunkBuilder {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let sectionHeading: String?
        var lines: [DiffLine] = []
        var nextOldLine: Int
        var nextNewLine: Int

        /// True once the hunk has consumed the line counts its header declared.
        var isComplete: Bool {
            nextOldLine - oldStart >= oldCount && nextNewLine - newStart >= newCount
        }

        init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, sectionHeading: String?) {
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
            self.sectionHeading = sectionHeading
            nextOldLine = oldStart
            nextNewLine = newStart
        }

        func build() -> DiffHunk {
            DiffHunk(
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                sectionHeading: sectionHeading,
                lines: lines
            )
        }
    }

    final class FileBuilder {
        var headerLines: [String] = []
        var oldPath = ""
        var newPath = ""
        var sawOldPath = false
        var sawNewPath = false
        var isBinary = false
        var isNewFile = false
        var isDeletedFile = false
        var renameFrom: String?
        var renameTo: String?
        var gitOldPath: String?
        var gitNewPath: String?
        var hunks: [DiffHunk] = []
        var currentHunk: HunkBuilder?

        func setOldPath(_ path: String) {
            oldPath = path
            sawOldPath = true
        }

        func setNewPath(_ path: String) {
            newPath = path
            sawNewPath = true
        }

        /// Extract paths from `diff --git a/x b/y` as a fallback for files
        /// with no `---`/`+++` lines (pure renames, mode changes, binary).
        func parseGitHeader(_ line: String) {
            let payload = line.dropFirst("diff --git ".count)
            let parts = payload.split(separator: " ")
            guard parts.count == 2 else { return }
            if parts[0].hasPrefix("a/") { gitOldPath = String(parts[0].dropFirst(2)) }
            if parts[1].hasPrefix("b/") { gitNewPath = String(parts[1].dropFirst(2)) }
        }

        func appendHunkLine(_ line: String) {
            guard let hunk = currentHunk else { return }
            if line.hasPrefix("+") {
                hunk.lines.append(DiffLine(
                    kind: .addition,
                    text: String(line.dropFirst()),
                    oldLine: nil,
                    newLine: hunk.nextNewLine
                ))
                hunk.nextNewLine += 1
            } else if line.hasPrefix("-") {
                hunk.lines.append(DiffLine(
                    kind: .removal,
                    text: String(line.dropFirst()),
                    oldLine: hunk.nextOldLine,
                    newLine: nil
                ))
                hunk.nextOldLine += 1
            } else if line.hasPrefix("\\") {
                hunk.lines.append(DiffLine(
                    kind: .noNewline,
                    text: line.dropFirst().trimmingCharacters(in: .whitespaces),
                    oldLine: nil,
                    newLine: nil
                ))
            } else if line.hasPrefix(" ") || line.isEmpty {
                // An empty line inside a hunk is a context line whose content is empty.
                hunk.lines.append(DiffLine(
                    kind: .context,
                    text: line.isEmpty ? "" : String(line.dropFirst()),
                    oldLine: hunk.nextOldLine,
                    newLine: hunk.nextNewLine
                ))
                hunk.nextOldLine += 1
                hunk.nextNewLine += 1
            } else {
                // Anything else ends the hunk (start of the next file section).
                closeHunk()
            }
        }

        func closeHunk() {
            if let hunk = currentHunk {
                hunks.append(hunk.build())
                currentHunk = nil
            }
        }

        func build() -> FileDiff? {
            closeHunk()
            let resolvedOld = sawOldPath ? oldPath : (gitOldPath ?? "")
            let resolvedNew = sawNewPath ? newPath : (gitNewPath ?? "")
            guard !headerLines.isEmpty else { return nil }
            guard !resolvedOld.isEmpty || !resolvedNew.isEmpty else { return nil }

            let kind: FileDiff.Kind
            if isBinary {
                kind = .binary
            } else if let from = renameFrom, renameTo != nil {
                kind = .renamed(from: from)
            } else if isNewFile || (resolvedOld.isEmpty && !resolvedNew.isEmpty) {
                kind = .created
            } else if isDeletedFile || (resolvedNew.isEmpty && !resolvedOld.isEmpty) {
                kind = .deleted
            } else {
                kind = .modified
            }

            return FileDiff(
                oldPath: resolvedOld,
                newPath: resolvedNew,
                kind: kind,
                headerLines: headerLines,
                hunks: hunks
            )
        }
    }
}
