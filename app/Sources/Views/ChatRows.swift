import SwiftUI

/// A single transcript row.
struct ChatRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            Text(item.text)
                .textSelection(.enabled)
        case .thinking:
            DisclosureGroup("Thinking") {
                Text(item.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .status:
            Text(item.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        case .tool:
            if let tool = item.tool {
                ToolCallCard(tool: tool)
            }
        }
    }
}

/// Card for one tool invocation: name, target, and expandable result.
struct ToolCallCard: View {
    let tool: ToolCallInfo
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                Text(tool.name)
                    .font(.subheadline.weight(.medium))
                if !tool.inputSummary.isEmpty {
                    Text(tool.inputSummary)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            if expanded, let result = tool.result {
                Text(result)
                    .font(.footnote.monospaced())
                    .foregroundStyle(tool.isError ? .red : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(20)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            guard tool.result != nil else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                expanded.toggle()
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if tool.isRunning {
            ProgressView()
                .controlSize(.small)
        } else if tool.isError {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
