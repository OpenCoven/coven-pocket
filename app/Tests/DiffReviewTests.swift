import XCTest
@testable import CovenPocket

final class SideBySidePairingTests: XCTestCase {
    private func hunk(_ diff: String) -> DiffHunk {
        UnifiedDiffParser.parse(diff)[0].hunks[0]
    }

    func testPairsRemovalWithAdditionInSameRun() {
        let rows = SideBySidePairing.rows(for: hunk("""
        --- a/f
        +++ b/f
        @@ -1,3 +1,3 @@
         ctx
        -old line
        +new line
         tail
        """))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].old?.kind, .context)
        XCTAssertEqual(rows[1].old?.kind, .removal)
        XCTAssertEqual(rows[1].new?.kind, .addition)
        XCTAssertEqual(rows[2].old?.kind, .context)
    }

    func testUnbalancedRunLeavesEmptyOppositeSide() {
        let rows = SideBySidePairing.rows(for: hunk("""
        --- a/f
        +++ b/f
        @@ -1,2 +1,3 @@
        -only removal
        +first addition
        +second addition
         ctx
        """))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].old?.kind, .removal)
        XCTAssertEqual(rows[0].new?.kind, .addition)
        XCTAssertNil(rows[1].old)
        XCTAssertEqual(rows[1].new?.text, "second addition")
    }

    func testContextFlushesPendingRun() {
        let rows = SideBySidePairing.rows(for: hunk("""
        --- a/f
        +++ b/f
        @@ -1,3 +1,3 @@
        -gone
         mid
        +arrived
         end
        """))
        // Removal alone, then context, then addition alone, then context.
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].old?.kind, .removal)
        XCTAssertNil(rows[0].new)
        XCTAssertEqual(rows[1].old?.text, "mid")
        XCTAssertNil(rows[2].old)
        XCTAssertEqual(rows[2].new?.kind, .addition)
    }
}

@MainActor
final class DiffReviewModelTests: XCTestCase {
    func testAcceptAllAndPatch() {
        let model = DiffReviewModel(diffText: DiffSamples.multiFile)
        XCTAssertNil(model.acceptedPatch)
        XCTAssertEqual(model.pendingCount, model.totalCount)

        model.acceptAll()
        XCTAssertEqual(model.acceptedCount, model.totalCount)
        XCTAssertTrue(model.isFullyReviewed)
        XCTAssertNotNil(model.acceptedPatch)
    }

    func testRejectAllYieldsNoPatch() {
        let model = DiffReviewModel(diffText: DiffSamples.multiFile)
        model.rejectAll()
        XCTAssertNil(model.acceptedPatch)
        XCTAssertTrue(model.isFullyReviewed)
    }

    func testPerFileDecisions() {
        let model = DiffReviewModel(diffText: DiffSamples.multiFile)
        let created = model.files[1]
        model.acceptAll(in: created)
        XCTAssertEqual(model.acceptedCount, created.hunks.count)
        let patch = model.acceptedPatch
        XCTAssertNotNil(patch)
        XCTAssertTrue(patch!.contains("SessionStore.swift"))
        XCTAssertFalse(patch!.contains("Legacy.swift"))
    }

    func testToggleDecision() {
        let model = DiffReviewModel(diffText: DiffSamples.multiFile)
        let hunkId = model.files[0].hunks[0].id
        model.setDecision(.accepted, for: hunkId)
        XCTAssertEqual(model.decision(for: hunkId), .accepted)
        model.setDecision(.pending, for: hunkId)
        XCTAssertEqual(model.decision(for: hunkId), .pending)
    }
}
