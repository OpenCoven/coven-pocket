import SwiftUI

/// How diff content is laid out.
enum DiffViewMode: String, CaseIterable, Identifiable {
    case inline
    case sideBySide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inline: return "Inline"
        case .sideBySide: return "Split"
        }
    }

    var systemImage: String {
        switch self {
        case .inline: return "list.bullet"
        case .sideBySide: return "rectangle.split.2x1"
        }
    }
}

/// Full-screen diff review: per-file sections, per-hunk accept/reject, and an
/// Apply action that hands the accepted subset back as a unified diff.
struct DiffReviewView: View {
    @ObservedObject var model: DiffReviewModel
    @AppStorage("diffViewMode") private var mode: DiffViewMode = .inline
    /// Called with the accepted-hunks patch when the user taps Apply.
    var onApply: ((String) -> Void)?

    var body: some View {
        Group {
            if model.files.isEmpty {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "doc.text",
                    description: Text("The diff is empty or could not be parsed.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.files) { file in
                            FileDiffSection(file: file, model: model, mode: mode)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle("Review Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Layout", selection: $mode) {
                    ForEach(DiffViewMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Reject All", role: .destructive) { model.rejectAll() }
                Spacer()
                reviewProgress
                Spacer()
                Button("Accept All") { model.acceptAll() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let onApply {
                applyBar(onApply)
            }
        }
    }

    private var reviewProgress: some View {
        Text("\(model.acceptedCount)/\(model.totalCount) accepted")
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func applyBar(_ apply: @escaping (String) -> Void) -> some View {
        // Rebuilding the patch walks every hunk; do it once per render.
        let patch = model.acceptedPatch
        return HStack {
            Button {
                if let patch { apply(patch) }
            } label: {
                Text("Apply Accepted Changes")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(patch == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - File section

private struct FileDiffSection: View {
    let file: FileDiff
    @ObservedObject var model: DiffReviewModel
    let mode: DiffViewMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if file.hunks.isEmpty {
                hunklessBody
            } else {
                ForEach(file.hunks) { hunk in
                    HunkView(hunk: hunk, model: model, mode: mode)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            kindBadge
            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayPath)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                if case let .renamed(from) = file.kind {
                    Text("from \(from)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            if file.additions > 0 {
                Text("+\(file.additions)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
            }
            if file.deletions > 0 {
                Text("−\(file.deletions)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.red)
            }
            Menu {
                Button("Accept File") { model.acceptAll(in: file) }
                Button("Reject File", role: .destructive) { model.rejectAll(in: file) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.medium)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground))
    }

    private var kindBadge: some View {
        Group {
            switch file.kind {
            case .created:
                badge("A", .green)
            case .deleted:
                badge("D", .red)
            case .renamed:
                badge("R", .orange)
            case .binary:
                badge("B", .secondary)
            case .modified:
                badge("M", .blue)
            }
        }
    }

    private func badge(_ letter: String, _ color: Color) -> some View {
        Text(letter)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Binary / pure-rename files: a single file-level decision row.
    private var hunklessBody: some View {
        HStack {
            Text(file.kind == .binary ? "Binary file" : "No content changes")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            DecisionControl(decision: model.decision(for: file.id)) { decision in
                model.setDecision(decision, for: file.id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Hunk

private struct HunkView: View {
    let hunk: DiffHunk
    @ObservedObject var model: DiffReviewModel
    let mode: DiffViewMode

    private var decision: HunkDecision { model.decision(for: hunk.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hunkBar
            if decision != .rejected {
                content
                    .opacity(decision == .accepted ? 1 : 0.92)
            }
        }
    }

    private var hunkBar: some View {
        HStack(spacing: 8) {
            Text(hunk.header(oldStart: hunk.oldStart, newStart: hunk.newStart))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            DecisionControl(decision: decision) { decision in
                model.setDecision(decision, for: hunk.id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(decisionTint)
    }

    private var decisionTint: Color {
        switch decision {
        case .accepted: return Color.green.opacity(0.08)
        case .rejected: return Color.red.opacity(0.08)
        case .pending: return Color(.tertiarySystemGroupedBackground).opacity(0.6)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .inline:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunk.lines) { line in
                    InlineLineRow(line: line)
                }
            }
        case .sideBySide:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SideBySidePairing.rows(for: hunk)) { row in
                    SideBySideLineRow(row: row)
                }
            }
        }
    }
}

// MARK: - Decision control

private struct DecisionControl: View {
    let decision: HunkDecision
    let set: (HunkDecision) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                set(decision == .rejected ? .pending : .rejected)
            } label: {
                Image(systemName: decision == .rejected ? "xmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(decision == .rejected ? .red : .secondary)
            }
            Button {
                set(decision == .accepted ? .pending : .accepted)
            } label: {
                Image(systemName: decision == .accepted ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(decision == .accepted ? .green : .secondary)
            }
        }
        .buttonStyle(.plain)
        .imageScale(.large)
    }
}

// MARK: - Previews

#Preview("Diff review") {
    NavigationStack {
        DiffReviewView(model: DiffReviewModel(diffText: DiffSamples.multiFile)) { patch in
            print(patch)
        }
    }
}
