import Foundation

/// One row of a side-by-side diff: an optional old-side line paired with an
/// optional new-side line.
struct SideBySideRow: Identifiable, Equatable {
    let id: UUID
    let old: DiffLine?
    let new: DiffLine?

    init(id: UUID = UUID(), old: DiffLine?, new: DiffLine?) {
        self.id = id
        self.old = old
        self.new = new
    }
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

        func flushRun() {
            let count = max(removals.count, additions.count)
            for index in 0 ..< count {
                rows.append(SideBySideRow(
                    old: index < removals.count ? removals[index] : nil,
                    new: index < additions.count ? additions[index] : nil
                ))
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
                rows.append(SideBySideRow(old: line, new: line))
            case .noNewline:
                // Attach to whichever side received the previous line.
                if !additions.isEmpty {
                    additions.append(line)
                } else if !removals.isEmpty {
                    removals.append(line)
                } else {
                    flushRun()
                    rows.append(SideBySideRow(old: line, new: line))
                }
            }
        }
        flushRun()
        return rows
    }
}
