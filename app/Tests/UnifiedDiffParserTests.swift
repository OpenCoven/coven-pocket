import XCTest
@testable import CovenPocket

final class UnifiedDiffParserTests: XCTestCase {
    func testParsesMultiFileSample() {
        let files = UnifiedDiffParser.parse(DiffSamples.multiFile)
        XCTAssertEqual(files.count, 3)

        XCTAssertEqual(files[0].displayPath, "Sources/App/Session.swift")
        XCTAssertEqual(files[0].kind, .modified)
        XCTAssertEqual(files[0].hunks.count, 2)
        XCTAssertEqual(files[0].additions, 3)
        XCTAssertEqual(files[0].deletions, 2)

        XCTAssertEqual(files[1].displayPath, "Sources/App/SessionStore.swift")
        XCTAssertEqual(files[1].kind, .created)
        XCTAssertEqual(files[1].oldPath, "")
        XCTAssertEqual(files[1].additions, 5)

        XCTAssertEqual(files[2].displayPath, "Sources/App/Legacy.swift")
        XCTAssertEqual(files[2].kind, .deleted)
        XCTAssertEqual(files[2].newPath, "")
        XCTAssertEqual(files[2].deletions, 3)
    }

    func testHunkHeaderAndSectionHeading() {
        let files = UnifiedDiffParser.parse(DiffSamples.multiFile)
        let hunk = files[0].hunks[0]
        XCTAssertEqual(hunk.oldStart, 1)
        XCTAssertEqual(hunk.oldCount, 6)
        XCTAssertEqual(hunk.newStart, 1)
        XCTAssertEqual(hunk.newCount, 7)
        XCTAssertEqual(hunk.sectionHeading, "struct Session")
    }

    func testLineNumbersAreAssigned() {
        let files = UnifiedDiffParser.parse(DiffSamples.multiFile)
        let lines = files[0].hunks[0].lines

        XCTAssertEqual(lines[0].kind, .context)
        XCTAssertEqual(lines[0].oldLine, 1)
        XCTAssertEqual(lines[0].newLine, 1)

        let removal = lines.first { $0.kind == .removal }
        XCTAssertEqual(removal?.oldLine, 4)
        XCTAssertNil(removal?.newLine)

        let addition = lines.first { $0.kind == .addition }
        XCTAssertNil(addition?.oldLine)
        XCTAssertEqual(addition?.newLine, 4)
    }

    func testOmittedCountDefaultsToOne() {
        let diff = """
        --- a/f.txt
        +++ b/f.txt
        @@ -3 +3 @@
        -old
        +new
        """
        let files = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        let hunk = files[0].hunks[0]
        XCTAssertEqual(hunk.oldCount, 1)
        XCTAssertEqual(hunk.newCount, 1)
        XCTAssertEqual(hunk.lines.count, 2)
    }

    func testBareUnifiedDiffWithoutGitHeader() {
        let diff = """
        --- a/x.txt
        +++ b/x.txt
        @@ -1,2 +1,2 @@
         keep
        -drop
        +add
        """
        let files = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].kind, .modified)
        XCTAssertEqual(files[0].hunks[0].lines.count, 3)
    }

    func testNoNewlineMarkerStaysInHunk() {
        let diff = """
        --- a/f.txt
        +++ b/f.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let files = UnifiedDiffParser.parse(diff)
        let lines = files[0].hunks[0].lines
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[1].kind, .noNewline)
        XCTAssertEqual(lines[3].kind, .noNewline)
    }

    func testBinaryFile() {
        let diff = """
        diff --git a/logo.png b/logo.png
        index 1111111..2222222 100644
        Binary files a/logo.png and b/logo.png differ
        """
        let files = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].kind, .binary)
        XCTAssertEqual(files[0].displayPath, "logo.png")
        XCTAssertTrue(files[0].hunks.isEmpty)
    }

    func testPureRename() {
        let diff = """
        diff --git a/old_name.swift b/new_name.swift
        similarity index 100%
        rename from old_name.swift
        rename to new_name.swift
        """
        let files = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].kind, .renamed(from: "old_name.swift"))
        XCTAssertEqual(files[0].displayPath, "new_name.swift")
    }

    func testHunkContentStartingWithDashesIsNotAFileBoundary() {
        // A removal line whose content is `---` must not open a new file.
        let diff = """
        --- a/doc.md
        +++ b/doc.md
        @@ -1,2 +1,2 @@
         title
        ----
        +==
        """
        let files = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].hunks[0].deletions, 1)
        XCTAssertEqual(files[0].hunks[0].lines[1].text, "---")
    }

    func testGarbageReturnsEmpty() {
        XCTAssertTrue(UnifiedDiffParser.parse("not a diff at all").isEmpty)
        XCTAssertTrue(UnifiedDiffParser.parse("").isEmpty)
    }
}
