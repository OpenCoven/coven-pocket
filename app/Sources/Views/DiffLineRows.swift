import SwiftUI

// MARK: - Line rows

struct InlineLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LineNumberGutter(number: line.oldLine)
            LineNumberGutter(number: line.newLine)
            Text(markerText)
                .font(.caption.monospaced())
                .foregroundStyle(markerColor)
                .frame(width: 12)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.caption.monospaced())
                .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(DiffColors.background(for: line.kind))
    }

    private var markerText: String {
        switch line.kind {
        case .addition: return "+"
        case .removal: return "−"
        case .context: return " "
        case .noNewline: return "\\"
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: return .green
        case .removal: return .red
        case .context, .noNewline: return .secondary
        }
    }
}

struct SideBySideLineRow: View {
    let row: SideBySideRow

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sideCell(row.old, isOld: true)
            Divider()
            sideCell(row.new, isOld: false)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func sideCell(_ line: DiffLine?, isOld: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            LineNumberGutter(number: isOld ? line?.oldLine : line?.newLine)
            Text(line.map { $0.text.isEmpty ? " " : $0.text } ?? " ")
                .font(.caption.monospaced())
                .foregroundStyle(line?.kind == .noNewline ? .secondary : .primary)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(sideBackground(line, isOld: isOld))
    }

    private func sideBackground(_ line: DiffLine?, isOld: Bool) -> Color {
        guard let line else { return Color(.systemFill).opacity(0.25) }
        switch line.kind {
        case .context, .noNewline:
            return .clear
        case .addition:
            return isOld ? .clear : DiffColors.background(for: .addition)
        case .removal:
            return isOld ? DiffColors.background(for: .removal) : .clear
        }
    }
}

struct LineNumberGutter: View {
    let number: Int?

    var body: some View {
        Text(number.map(String.init) ?? "")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 4)
    }
}

enum DiffColors {
    static func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Color.green.opacity(0.12)
        case .removal: return Color.red.opacity(0.12)
        case .context, .noNewline: return .clear
        }
    }
}
