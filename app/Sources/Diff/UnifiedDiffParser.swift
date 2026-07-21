import Foundation

/// Parses unified diff text (as produced by `git diff` and the engine's
/// apply_patch tooling) into `FileDiff` values.
///
/// The parser is tolerant: unrecognized lines between files are skipped, and
/// a diff that starts directly at `--- old` / `+++ new` (no `diff --git`
/// header) is accepted.
enum UnifiedDiffParser {
    /// Parse a complete diff, possibly spanning multiple files.
    static func parse(_ text: String) -> [FileDiff] {
        let state = ParserState()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            state.process(String(rawLine))
        }
        return state.finish()
    }

    /// Line-by-line parsing state: the files finished so far plus the file
    /// currently being assembled.
    private final class ParserState {
        private var files: [FileDiff] = []
        private var builder: FileBuilder?

        func process(_ line: String) {
            // `\ No newline at end of file` belongs to the hunk even though it
            // arrives after the declared counts are consumed.
            if line.hasPrefix("\\"), let current = builder, current.currentHunk != nil {
                current.appendHunkLine(line)
                return
            }

            // Once a hunk has consumed its declared line counts, subsequent
            // lines belong to headers again. This disambiguates content lines
            // that start with `---`/`+++` from file boundaries.
            if let current = builder, let hunk = current.currentHunk, hunk.isComplete {
                current.closeHunk()
            }

            if consumeFileBoundary(line) { return }
            guard let current = builder else { return }
            if consumeHunkContent(line, in: current) { return }
            consumeMetadata(line, in: current)
        }

        func finish() -> [FileDiff] {
            if let file = builder?.build() { files.append(file) }
            builder = nil
            return files
        }

        private func startFile() {
            if let file = builder?.build() { files.append(file) }
            builder = FileBuilder()
        }

        /// Handle lines that open a new file section. Returns true if consumed.
        private func consumeFileBoundary(_ line: String) -> Bool {
            if line.hasPrefix("diff --git ") {
                startFile()
                builder?.headerLines.append(line)
                builder?.parseGitHeader(line)
                return true
            }
            if line.hasPrefix("--- "), builder?.currentHunk == nil {
                // A bare `---` opens a new file when no git header preceded it.
                if builder == nil || builder?.sawOldPath == true {
                    startFile()
                }
                builder?.headerLines.append(line)
                builder?.setOldPath(stripPathPrefix(String(line.dropFirst(4))))
                return true
            }
            return false
        }

        /// Handle `+++`, `@@`, and hunk body lines. Returns true if consumed.
        private func consumeHunkContent(_ line: String, in current: FileBuilder) -> Bool {
            if line.hasPrefix("+++ "), current.currentHunk == nil {
                current.headerLines.append(line)
                current.setNewPath(stripPathPrefix(String(line.dropFirst(4))))
                return true
            }
            if line.hasPrefix("@@") {
                if let hunk = parseHunkHeader(line) {
                    current.closeHunk()
                    current.currentHunk = hunk
                }
                return true
            }
            if current.currentHunk != nil {
                current.appendHunkLine(line)
                return true
            }
            return false
        }

        /// Metadata lines between the file header and the first hunk.
        private func consumeMetadata(_ line: String, in current: FileBuilder) {
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current.headerLines.append(line)
                current.isBinary = true
            } else if line.hasPrefix("rename from ") {
                current.headerLines.append(line)
                current.renameFrom = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                current.headerLines.append(line)
                current.renameTo = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("new file mode ") {
                current.headerLines.append(line)
                current.isNewFile = true
            } else if line.hasPrefix("deleted file mode ") {
                current.headerLines.append(line)
                current.isDeletedFile = true
            } else if line.hasPrefix("index ")
                || line.hasPrefix("old mode ")
                || line.hasPrefix("new mode ")
                || line.hasPrefix("similarity index ") {
                current.headerLines.append(line)
            }
        }
    }

    /// Strip the conventional `a/` / `b/` prefixes; map `/dev/null` to empty.
    private static func stripPathPrefix(_ path: String) -> String {
        // `--- a/path\ttimestamp` forms exist; cut at the first tab.
        let trimmed = path.split(separator: "\t", maxSplits: 1)[0]
        if trimmed == "/dev/null" { return "" }
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
            return String(trimmed.dropFirst(2))
        }
        return String(trimmed)
    }

    /// Parse `@@ -l[,c] +l[,c] @@ heading` into an empty hunk shell.
    private static func parseHunkHeader(_ line: String) -> HunkBuilder? {
        // Find the closing `@@`.
        guard line.hasPrefix("@@ ") else { return nil }
        let afterOpen = line.index(line.startIndex, offsetBy: 3)
        guard let closeRange = line.range(of: " @@", range: afterOpen ..< line.endIndex) else {
            return nil
        }
        let rangesPart = line[afterOpen ..< closeRange.lowerBound]
        let headingPart = line[closeRange.upperBound...]

        let pieces = rangesPart.split(separator: " ")
        guard pieces.count == 2,
              pieces[0].hasPrefix("-"),
              pieces[1].hasPrefix("+"),
              let old = parseRange(pieces[0].dropFirst()),
              let new = parseRange(pieces[1].dropFirst())
        else { return nil }

        let heading = headingPart.trimmingCharacters(in: .whitespaces)
        return HunkBuilder(
            oldStart: old.start,
            oldCount: old.count,
            newStart: new.start,
            newCount: new.count,
            sectionHeading: heading.isEmpty ? nil : heading
        )
    }

    /// Parse `l` or `l,c`; a missing count means 1.
    private static func parseRange(_ text: Substring) -> (start: Int, count: Int)? {
        let parts = text.split(separator: ",", maxSplits: 1)
        guard let start = Int(parts[0]) else { return nil }
        let count = parts.count == 2 ? Int(parts[1]) : 1
        guard let count else { return nil }
        return (start, count)
    }
}
