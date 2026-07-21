import Foundation

/// Review decision for a single hunk (or a hunk-less file).
enum HunkDecision: Equatable {
    case pending
    case accepted
    case rejected
}

/// Observable review state over a parsed diff: which hunks the user has
/// accepted or rejected, and the resulting partial patch.
@MainActor
final class DiffReviewModel: ObservableObject {
    let files: [FileDiff]
    @Published private(set) var decisions: [UUID: HunkDecision] = [:]

    init(files: [FileDiff]) {
        self.files = files
    }

    convenience init(diffText: String) {
        self.init(files: UnifiedDiffParser.parse(diffText))
    }

    // MARK: - Decisions

    /// The decision units of a file: its hunks, or the file itself when it has
    /// no hunks (binary / pure rename).
    private func decisionIds(for file: FileDiff) -> [UUID] {
        file.hunks.isEmpty ? [file.id] : file.hunks.map(\.id)
    }

    private var allDecisionIds: [UUID] {
        files.flatMap { decisionIds(for: $0) }
    }

    func decision(for id: UUID) -> HunkDecision {
        decisions[id] ?? .pending
    }

    func setDecision(_ decision: HunkDecision, for id: UUID) {
        decisions[id] = decision
    }

    func acceptAll() {
        for id in allDecisionIds { decisions[id] = .accepted }
    }

    func rejectAll() {
        for id in allDecisionIds { decisions[id] = .rejected }
    }

    func acceptAll(in file: FileDiff) {
        for id in decisionIds(for: file) { decisions[id] = .accepted }
    }

    func rejectAll(in file: FileDiff) {
        for id in decisionIds(for: file) { decisions[id] = .rejected }
    }

    // MARK: - Aggregates

    var totalCount: Int { allDecisionIds.count }
    var acceptedCount: Int { allDecisionIds.filter { decision(for: $0) == .accepted }.count }
    var rejectedCount: Int { allDecisionIds.filter { decision(for: $0) == .rejected }.count }
    var pendingCount: Int { totalCount - acceptedCount - rejectedCount }

    /// True when every hunk has a decision.
    var isFullyReviewed: Bool { pendingCount == 0 && totalCount > 0 }

    /// The unified diff of everything currently accepted, or `nil` when no
    /// hunk is accepted yet.
    var acceptedPatch: String? {
        let accepted = Set(allDecisionIds.filter { decision(for: $0) == .accepted })
        return DiffPatchBuilder.patch(files: files, accepting: accepted)
    }
}
