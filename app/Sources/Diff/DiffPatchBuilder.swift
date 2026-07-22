import Foundation

/// Rebuilds a valid unified diff containing only the accepted hunks.
///
/// When earlier hunks are rejected, the `+new` start positions of later hunks
/// shift because the insertions/deletions those hunks would have made never
/// happen. This builder rebases each accepted hunk's new-file start so the
/// emitted patch stays internally consistent and applies cleanly to the
/// original file.
enum DiffPatchBuilder {
    /// Build a patch for several files. Files whose hunks are all rejected are
    /// omitted. Returns `nil` when nothing was accepted.
    static func patch(files: [FileDiff], accepting accepted: Set<UUID>) -> String? {
        let parts = files.compactMap { patch(file: $0, accepting: accepted) }
        guard !parts.isEmpty else { return nil }
        return parts.joined()
    }

    /// Build a patch for a single file. Returns `nil` when no hunk is accepted.
    ///
    /// Binary and pure-rename diffs carry no hunks; they are all-or-nothing
    /// and are included when `accepted` contains the file's `id`.
    static func patch(file: FileDiff, accepting accepted: Set<UUID>) -> String? {
        if file.hunks.isEmpty {
            guard accepted.contains(file.id) else { return nil }
            return file.headerLines.joined(separator: "\n") + "\n"
        }

        let acceptedHunks = file.hunks.filter { accepted.contains($0.id) }
        guard !acceptedHunks.isEmpty else { return nil }

        var out = file.headerLines.joined(separator: "\n") + "\n"
        var delta = 0
        for hunk in acceptedHunks {
            let newStart = rebasedNewStart(for: hunk, delta: delta)
            out += hunk.header(oldStart: hunk.oldStart, newStart: newStart) + "\n"
            for line in hunk.lines {
                out += line.rawLine + "\n"
            }
            delta += hunk.newCount - hunk.oldCount
        }
        return out
    }

    /// Compute the new-file start for a hunk given the cumulative line delta
    /// of the accepted hunks before it.
    ///
    /// Unified diff convention: a zero-count range refers to the position
    /// *after* which the change happens, so insertion-only hunks sit one line
    /// below their old anchor and deletion-only hunks one line above their
    /// rebased position.
    static func rebasedNewStart(for hunk: DiffHunk, delta: Int) -> Int {
        if hunk.oldCount == 0 {
            return hunk.oldStart + delta + 1
        }
        if hunk.newCount == 0 {
            return hunk.oldStart + delta - 1
        }
        return hunk.oldStart + delta
    }
}
