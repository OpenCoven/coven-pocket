import Foundation

/// One file's worth of changes inside a unified diff.
struct FileDiff: Identifiable, Equatable {
    enum Kind: Equatable {
        case modified
        case created
        case deleted
        case renamed(from: String)
        case binary
    }

    let id: UUID
    /// Path on the old side, with the `a/` prefix stripped. Empty for created files.
    let oldPath: String
    /// Path on the new side, with the `b/` prefix stripped. Empty for deleted files.
    let newPath: String
    let kind: Kind
    /// Header lines exactly as they appeared in the source diff (everything
    /// from `diff --git` / `---` up to the first hunk). Re-emitted verbatim
    /// when building a patch so `git apply` metadata survives.
    let headerLines: [String]
    let hunks: [DiffHunk]

    init(
        id: UUID = UUID(),
        oldPath: String,
        newPath: String,
        kind: Kind,
        headerLines: [String],
        hunks: [DiffHunk]
    ) {
        self.id = id
        self.oldPath = oldPath
        self.newPath = newPath
        self.kind = kind
        self.headerLines = headerLines
        self.hunks = hunks
    }

    /// The path to show in UI: the new path, falling back to the old one for deletions.
    var displayPath: String { newPath.isEmpty ? oldPath : newPath }

    var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }
}

/// A contiguous `@@ -old +new @@` change region.
struct DiffHunk: Identifiable, Equatable {
    let id: UUID
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    /// Optional function/section context after the closing `@@`.
    let sectionHeading: String?
    let lines: [DiffLine]

    init(
        id: UUID = UUID(),
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        sectionHeading: String?,
        lines: [DiffLine]
    ) {
        self.id = id
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.sectionHeading = sectionHeading
        self.lines = lines
    }

    var additions: Int { lines.filter { $0.kind == .addition }.count }
    var deletions: Int { lines.filter { $0.kind == .removal }.count }

    /// The `@@ -a,b +c,d @@` header with the given start values.
    func header(oldStart: Int, newStart: Int) -> String {
        var text = "@@ -\(Self.range(oldStart, oldCount)) +\(Self.range(newStart, newCount)) @@"
        if let heading = sectionHeading, !heading.isEmpty {
            text += " \(heading)"
        }
        return text
    }

    private static func range(_ start: Int, _ count: Int) -> String {
        count == 1 ? "\(start)" : "\(start),\(count)"
    }
}

/// A single line inside a hunk.
struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case context
        case addition
        case removal
        /// A `\ No newline at end of file` marker attached to the previous line.
        case noNewline
    }

    let id: UUID
    let kind: Kind
    /// Line content without the leading `+`/`-`/` ` marker.
    let text: String
    /// 1-based line number in the old file, when the line exists there.
    let oldLine: Int?
    /// 1-based line number in the new file, when the line exists there.
    let newLine: Int?

    init(id: UUID = UUID(), kind: Kind, text: String, oldLine: Int?, newLine: Int?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }

    /// The raw diff representation, marker included.
    var rawLine: String {
        switch kind {
        case .context: return " \(text)"
        case .addition: return "+\(text)"
        case .removal: return "-\(text)"
        case .noNewline: return "\\ \(text)"
        }
    }
}
