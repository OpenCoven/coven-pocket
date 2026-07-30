import Foundation

enum FamiliarProfileKey: Hashable {
    case codex(profileID: String)
    case companion(host: String, port: UInt16)

    var storageValue: String {
        switch self {
        case let .codex(profileID): return "codex:\(profileID)"
        case let .companion(host, port):
            return "companion:\(host.lowercased()):\(port)"
        }
    }
}

struct FamiliarSelectionStore {
    static let storageKey = "familiar-selections-v1"

    private struct Document: Codable {
        let version: Int
        var selections: [String: Snapshot]
    }

    private struct Snapshot: Codable {
        let id: String
        let displayName: String
        let emoji: String?
        let role: String?

        init(_ familiar: FamiliarIdentity) {
            id = familiar.id
            displayName = familiar.displayName
            emoji = familiar.emoji
            role = familiar.role
        }

        var familiar: FamiliarIdentity {
            FamiliarIdentity(
                id: id,
                displayName: displayName,
                emoji: emoji,
                role: role
            )
        }
    }

    private enum StoreError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            "Saved familiar selections could not be read."
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for profile: FamiliarProfileKey) throws -> FamiliarIdentity? {
        try loadDocument().selections[profile.storageValue]?.familiar
    }

    func save(
        _ familiar: FamiliarIdentity?,
        for profile: FamiliarProfileKey
    ) throws {
        var document = try loadDocument()
        if let familiar {
            document.selections[profile.storageValue] = Snapshot(familiar)
        } else {
            document.selections.removeValue(forKey: profile.storageValue)
        }
        let data = try JSONEncoder().encode(document)
        defaults.set(data, forKey: Self.storageKey)
    }

    private func loadDocument() throws -> Document {
        guard defaults.object(forKey: Self.storageKey) != nil else {
            return Document(version: 1, selections: [:])
        }

        do {
            guard let data = defaults.data(forKey: Self.storageKey) else {
                throw StoreError.unreadable
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else {
                throw StoreError.unreadable
            }
            return document
        } catch {
            defaults.removeObject(forKey: Self.storageKey)
            throw StoreError.unreadable
        }
    }
}
