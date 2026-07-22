import Foundation

/// One row of a side-by-side diff: an optional old-side line paired with an
/// optional new-side line. Identity is the row's position within its hunk,
/// which is stable across re-renders (`rows(for:)` is a pure function of the
/// hunk).
struct SideBySideRow: Identifiable, Equatable {
    let id: Int
    let old: DiffLine?
    let new: DiffLine?
}

enum SideBySidePairing {
    /// Pair a hunk's lines into side-by-side rows.
    ///
    /// Context lines occupy both columns. Within each contiguous run of
    /// changes, the k-th removal is paired with the k-th addition; leftovers
    /// render against an empty opposite column. `noNewline` markers stay
    /// attached to the side of the line they follow.
    static func rows(for hunk: DiffHunk) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        var removals: [DiffLine] = []
        var additions: [DiffLine] = []

        func append(old: DiffLine?, new: DiffLine?) {
            rows.append(SideBySideRow(id: rows.count, old: old, new: new))
        }

        func flushRun() {
            let count = max(removals.count, additions.count)
            for index in 0 ..< count {
                append(
                    old: index < removals.count ? removals[index] : nil,
                    new: index < additions.count ? additions[index] : nil
                )
            }
            removals.removeAll()
            additions.removeAll()
        }

        for line in hunk.lines {
            switch line.kind {
            case .removal:
                removals.append(line)
            case .addition:
                additions.append(line)
            case .context:
                flushRun()
                append(old: line, new: line)
            case .noNewline:
                // Attach to whichever side received the previous line.
                if !additions.isEmpty {
                    additions.append(line)
                } else if !removals.isEmpty {
                    removals.append(line)
                } else {
                    flushRun()
                    append(old: line, new: line)
                }
            }
        }
        flushRun()
        return rows
    }
}
