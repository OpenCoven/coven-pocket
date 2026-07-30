import XCTest
@testable import CovenPocket

final class FamiliarSelectionTests: XCTestCase {
    func testCodexSelectionRoundTripsExactSnapshot() throws {
        try withDefaults { defaults in
            let store = FamiliarSelectionStore(defaults: defaults)
            let familiar = FamiliarIdentity(
                id: "raven",
                displayName: "The Raven",
                emoji: "🐦‍⬛",
                role: "Research"
            )

            try store.save(familiar, for: .codex(profileID: "profile-a"))

            XCTAssertEqual(
                try store.load(for: .codex(profileID: "profile-a")),
                familiar
            )
        }
    }

    func testCodexProfilesAndCompanionEndpointAreIsolated() throws {
        try withDefaults { defaults in
            let store = FamiliarSelectionStore(defaults: defaults)
            let familiar = FamiliarIdentity(
                id: "owl",
                displayName: "The Owl",
                emoji: nil,
                role: "Planning"
            )

            try store.save(familiar, for: .codex(profileID: "profile-a"))

            XCTAssertNil(try store.load(for: .codex(profileID: "profile-b")))
            XCTAssertNil(
                try store.load(for: .companion(host: "mac.local", port: 49152))
            )
        }
    }

    func testCompanionKeysNormalizeHostCaseAndSeparatePorts() throws {
        try withDefaults { defaults in
            let store = FamiliarSelectionStore(defaults: defaults)
            let familiar = FamiliarIdentity(
                id: "fox",
                displayName: "The Fox",
                emoji: "🦊",
                role: nil
            )

            try store.save(
                familiar,
                for: .companion(host: "Mac.Tailnet.TS.NET", port: 49152)
            )

            XCTAssertEqual(
                try store.load(
                    for: .companion(host: "mac.tailnet.ts.net", port: 49152)
                ),
                familiar
            )
            XCTAssertNil(
                try store.load(
                    for: .companion(host: "mac.tailnet.ts.net", port: 49153)
                )
            )
        }
    }

    func testNilRemovesOnlySelectedProfile() throws {
        try withDefaults { defaults in
            let store = FamiliarSelectionStore(defaults: defaults)
            let first = FamiliarIdentity(
                id: "cat",
                displayName: "The Cat",
                emoji: "🐈",
                role: "Review"
            )
            let second = FamiliarIdentity(
                id: "wolf",
                displayName: "The Wolf",
                emoji: "🐺",
                role: "Execution"
            )
            let firstKey = FamiliarProfileKey.codex(profileID: "profile-a")
            let secondKey = FamiliarProfileKey.codex(profileID: "profile-b")
            try store.save(first, for: firstKey)
            try store.save(second, for: secondKey)

            try store.save(nil, for: firstKey)

            XCTAssertNil(try store.load(for: firstKey))
            XCTAssertEqual(try store.load(for: secondKey), second)
        }
    }

    func testCorruptDocumentThrowsAndRemovesOnlyFamiliarKey() throws {
        try withDefaults { defaults in
            defaults.set(Data([0xFF]), forKey: FamiliarSelectionStore.storageKey)
            defaults.set("preserve", forKey: "unrelated-key")
            let store = FamiliarSelectionStore(defaults: defaults)

            XCTAssertThrowsError(
                try store.load(for: .codex(profileID: "profile-a"))
            ) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "Saved familiar selections could not be read."
                )
            }
            XCTAssertNil(defaults.object(forKey: FamiliarSelectionStore.storageKey))
            XCTAssertEqual(defaults.string(forKey: "unrelated-key"), "preserve")
        }
    }

    func testUnsupportedDocumentVersionThrowsAndRemovesDocument() throws {
        try withDefaults { defaults in
            defaults.set(
                Data(#"{"version":2,"selections":{}}"#.utf8),
                forKey: FamiliarSelectionStore.storageKey
            )
            let store = FamiliarSelectionStore(defaults: defaults)

            XCTAssertThrowsError(
                try store.load(for: .codex(profileID: "profile-a"))
            ) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "Saved familiar selections could not be read."
                )
            }
            XCTAssertNil(defaults.object(forKey: FamiliarSelectionStore.storageKey))
        }
    }

    private func withDefaults(
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let suiteName = "familiar-selection-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
