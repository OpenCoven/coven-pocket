import Foundation
import CoreSpotlight
import os

/// Mirrors stored chat sessions into the on-device Spotlight index so they
/// can be found from system search and resumed via deep link.
enum SessionSpotlight {
    static let domain = "chat-sessions"
    private static let idPrefix = "session:"

    /// Build index entries from session summaries. Pure, so tests can
    /// assert attributes without touching the real index.
    static func searchableItems(for summaries: [ChatSessionSummary]) -> [CSSearchableItem] {
        let dates = ISO8601DateFormatter()
        return summaries.map { summary in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = summary.title.isEmpty ? "Untitled session" : summary.title
            attributes.contentDescription =
                "\(summary.model) · \(summary.messageCount) messages"
            attributes.contentModificationDate = dates.date(from: summary.updatedAt)
            return CSSearchableItem(
                uniqueIdentifier: idPrefix + summary.sessionId,
                domainIdentifier: domain,
                attributeSet: attributes
            )
        }
    }

    /// The session id carried by a Spotlight continuation activity, if any.
    static func sessionID(fromUniqueIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(idPrefix) else { return nil }
        let id = String(identifier.dropFirst(idPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// Replace the domain's entries with the current summaries. Failures are
    /// ignored: search is an accelerator, never a source of truth. Calls can
    /// overlap (list load racing a delete), so each carries a generation and
    /// only the newest one is allowed to write the final index.
    private static let generation = OSAllocatedUnfairLock(initialState: 0)

    static func reindex(_ summaries: [ChatSessionSummary]) {
        let mine = generation.withLock { state in
            state += 1
            return state
        }
        let items = searchableItems(for: summaries)
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            guard generation.withLock({ $0 }) == mine else { return }
            index.indexSearchableItems(items, completionHandler: nil)
        }
    }
}
