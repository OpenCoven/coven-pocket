import Foundation

/// Renders a chat transcript as a shareable markdown bundle.
///
/// Pure string work, no I/O — the redaction pass and upload live in
/// `GistShareModel`. Nothing may upload markdown that did not come out of
/// the engine's `redactSecrets`.
enum SessionExport {
    /// Title for a share: the first user message, trimmed to one line.
    static func title(for items: [ChatItem]) -> String {
        guard let first = items.first(where: { $0.kind == .user }) else {
            return "Coven Pocket session"
        }
        let line = first.text
            .components(separatedBy: .newlines)[0]
            .trimmingCharacters(in: .whitespaces)
        return line.count > 60 ? String(line.prefix(57)) + "…" : line
    }

    static func markdown(title: String, items: [ChatItem]) -> String {
        var parts: [String] = ["# \(title)"]
        for item in items {
            switch item.kind {
            case .user:
                parts.append("## You\n\n\(item.text)")
            case .assistant:
                parts.append("## Assistant\n\n\(item.text)")
            case .thinking:
                parts.append(
                    "<details><summary>Thinking</summary>\n\n\(item.text)\n\n</details>"
                )
            case .tool:
                parts.append(toolBlock(item))
            case .status:
                parts.append("> \(item.text)")
            case .error:
                parts.append("> WARNING: \(item.text)")
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    private static func toolBlock(_ item: ChatItem) -> String {
        guard let tool = item.tool else { return "### Tool\n\n\(item.text)" }
        var head = "### Tool: \(tool.name)"
        if !tool.inputSummary.isEmpty { head += " — \(tool.inputSummary)" }
        if tool.isError { head += " (failed)" }
        guard let result = tool.result, !result.isEmpty else { return head }
        return head + "\n\n" + fenced(result)
    }

    /// Fence `content`, escalating the fence length past any backtick runs
    /// inside it and tagging diffs so hosts highlight them.
    static func fenced(_ content: String) -> String {
        let longestRun = content
            .components(separatedBy: .newlines)
            .flatMap { line in
                line.split(omittingEmptySubsequences: false) { $0 != "`" }
                    .map(\.count)
            }
            .max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        let language = looksLikeDiff(content) ? "diff" : ""
        return "\(fence)\(language)\n\(content)\n\(fence)"
    }

    private static func looksLikeDiff(_ content: String) -> Bool {
        content.components(separatedBy: .newlines).contains { line in
            line.hasPrefix("@@") || line.hasPrefix("+++") || line.hasPrefix("---")
        }
    }
}
