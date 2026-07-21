import XCTest
@testable import CovenPocket

final class DiffPatchBuilderTests: XCTestCase {
    private func parse(_ text: String) -> [FileDiff] {
        UnifiedDiffParser.parse(text)
    }

    func testFullAcceptanceRoundTripsHunks() {
        let files = parse(DiffSamples.multiFile)
        let all = Set(files.flatMap { $0.hunks.map(\.id) })
        let patch = DiffPatchBuilder.patch(files: files, accepting: all)
        XCTAssertNotNil(patch)

        // Every original hunk header must appear unchanged.
        XCTAssertTrue(patch!.contains("@@ -1,6 +1,7 @@ struct Session"))
        XCTAssertTrue(patch!.contains("@@ -14,3 +15,3 @@ extension Session {"))
        XCTAssertTrue(patch!.contains("@@ -0,0 +1,5 @@"))
        XCTAssertTrue(patch!.contains("@@ -1,3 +0,0 @@"))
        // File headers are preserved verbatim.
        XCTAssertTrue(patch!.contains("new file mode 100644"))
        XCTAssertTrue(patch!.contains("deleted file mode 100644"))
    }

    func testNothingAcceptedReturnsNil() {
        let files = parse(DiffSamples.multiFile)
        XCTAssertNil(DiffPatchBuilder.patch(files: files, accepting: []))
    }

    func testRejectingFirstHunkRebasesSecond() {
        let files = parse(DiffSamples.multiFile)
        let session = files[0]
        // Reject hunk 1 (delta +1 not applied); accept only hunk 2.
        let patch = DiffPatchBuilder.patch(file: session, accepting: [session.hunks[1].id])
        XCTAssertNotNil(patch)
        // Original: @@ -14,3 +15,3 @@ — without hunk 1's +1 shift it must
        // become @@ -14,3 +14,3 @@.
        XCTAssertTrue(patch!.contains("@@ -14,3 +14,3 @@"), "got: \(patch!)")
        XCTAssertFalse(patch!.contains("let title"))
    }

    func testFullyRejectedFileIsOmitted() {
        let files = parse(DiffSamples.multiFile)
        // Accept only the created file's hunk.
        let created = files[1]
        let accepted = Set(created.hunks.map(\.id))
        let patch = DiffPatchBuilder.patch(files: files, accepting: accepted)
        XCTAssertNotNil(patch)
        XCTAssertTrue(patch!.contains("SessionStore.swift"))
        XCTAssertFalse(patch!.contains("Session.swift\n+++"))
        XCTAssertFalse(patch!.contains("Legacy.swift"))
    }

    func testInsertionOnlyHunkRebasing() {
        let diff = """
        --- a/f.txt
        +++ b/f.txt
        @@ -2,2 +2,3 @@
         a
        +inserted
         b
        @@ -5,0 +7,2 @@
        +tail one
        +tail two
        """
        let files = parse(diff)
        let hunks = files[0].hunks
        XCTAssertEqual(hunks.count, 2)

        // Accepting only the pure-insertion hunk: delta from hunk 1 (+1) is
        // gone, so `+7` rebases to oldStart(5) + 0 + 1 = 6.
        let patch = DiffPatchBuilder.patch(file: files[0], accepting: [hunks[1].id])
        XCTAssertTrue(patch!.contains("@@ -5,0 +6,2 @@"), "got: \(patch!)")

        // Accepting both keeps the original numbering.
        let both = DiffPatchBuilder.patch(file: files[0], accepting: Set(hunks.map(\.id)))
        XCTAssertTrue(both!.contains("@@ -5,0 +7,2 @@"), "got: \(both!)")
    }

    func testDeletionOnlyHunkRebasing() {
        let diff = """
        --- a/f.txt
        +++ b/f.txt
        @@ -1,2 +1,3 @@
         a
        +added
         b
        @@ -4,2 +5,0 @@
        -gone one
        -gone two
        """
        let files = parse(diff)
        let hunks = files[0].hunks

        // Without hunk 1's +1 delta the deletion hunk anchors at
        // oldStart(4) + 0 - 1 = 3.
        let patch = DiffPatchBuilder.patch(file: files[0], accepting: [hunks[1].id])
        XCTAssertTrue(patch!.contains("@@ -4,2 +3,0 @@"), "got: \(patch!)")
    }

    func testHunklessFileNeedsFileLevelAcceptance() {
        let diff = """
        diff --git a/logo.png b/logo.png
        Binary files a/logo.png and b/logo.png differ
        """
        let files = parse(diff)
        XCTAssertNil(DiffPatchBuilder.patch(files: files, accepting: []))
        let patch = DiffPatchBuilder.patch(files: files, accepting: [files[0].id])
        XCTAssertNotNil(patch)
        XCTAssertTrue(patch!.contains("Binary files"))
    }

    func testEmittedPatchParsesBack() {
        let files = parse(DiffSamples.multiFile)
        let all = Set(files.flatMap { $0.hunks.map(\.id) })
        let patch = DiffPatchBuilder.patch(files: files, accepting: all)!
        let reparsed = UnifiedDiffParser.parse(patch)
        XCTAssertEqual(reparsed.count, files.count)
        XCTAssertEqual(reparsed.map(\.additions), files.map(\.additions))
        XCTAssertEqual(reparsed.map(\.deletions), files.map(\.deletions))
    }
}
