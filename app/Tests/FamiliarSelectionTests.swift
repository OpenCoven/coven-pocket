import XCTest
@testable import CovenPocket

// swiftlint:disable file_length

private enum FakeFamiliarRosterError: LocalizedError {
    case transport

    var errorDescription: String? {
        "Roster transport failed."
    }
}

private final class PersistentlyCorruptFamiliarDefaults: UserDefaults {
    override func object(forKey defaultName: String) -> Any? {
        guard defaultName == FamiliarSelectionStore.storageKey else {
            return super.object(forKey: defaultName)
        }
        return Data([0xFF])
    }

    override func data(forKey defaultName: String) -> Data? {
        guard defaultName == FamiliarSelectionStore.storageKey else {
            return super.data(forKey: defaultName)
        }
        return Data([0xFF])
    }

    override func removeObject(forKey defaultName: String) {
        if defaultName != FamiliarSelectionStore.storageKey {
            super.removeObject(forKey: defaultName)
        }
    }
}

@MainActor
private final class FakeFamiliarRosterClient: FamiliarRosterClient {
    var gateResult: CompanionModel.SessionGate
    var familiarResult: Result<[RemoteFamiliar], Error> = .success([])
    var suspendsGate = false
    var suspendsFamiliars = false
    private(set) var gateCallCount = 0
    private(set) var requestedPairings: [DaemonPairing] = []

    private var gateExpectations: [XCTestExpectation] = []
    private var familiarExpectations: [XCTestExpectation] = []
    private var gateContinuations: [
        CheckedContinuation<CompanionModel.SessionGate, Never>
    ] = []
    private var familiarContinuations: [
        CheckedContinuation<[RemoteFamiliar], Error>
    ] = []

    init(gate: CompanionModel.SessionGate) {
        gateResult = gate
    }

    func gate() async -> CompanionModel.SessionGate {
        gateCallCount += 1
        fulfillNext(&gateExpectations)
        guard suspendsGate else { return gateResult }
        return await withCheckedContinuation { continuation in
            gateContinuations.append(continuation)
        }
    }

    func familiars(pairing: DaemonPairing) async throws -> [RemoteFamiliar] {
        requestedPairings.append(pairing)
        fulfillNext(&familiarExpectations)
        guard suspendsFamiliars else {
            return try familiarResult.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            familiarContinuations.append(continuation)
        }
    }

    func expectGate(_ description: String = "roster gate requested") -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        gateExpectations.append(expectation)
        return expectation
    }

    func expectFamiliars(
        _ description: String = "familiars requested"
    ) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        familiarExpectations.append(expectation)
        return expectation
    }

    func resumeNextGate(with result: CompanionModel.SessionGate) {
        guard !gateContinuations.isEmpty else { return }
        gateContinuations.removeFirst().resume(returning: result)
    }

    func resumeNextFamiliars(returning familiars: [RemoteFamiliar]) {
        guard !familiarContinuations.isEmpty else { return }
        familiarContinuations.removeFirst().resume(returning: familiars)
    }

    func resumeLastFamiliars(returning familiars: [RemoteFamiliar]) {
        guard let continuation = familiarContinuations.popLast() else { return }
        continuation.resume(returning: familiars)
    }

    private func fulfillNext(_ expectations: inout [XCTestExpectation]) {
        guard !expectations.isEmpty else { return }
        expectations.removeFirst().fulfill()
    }
}

@MainActor
// swiftlint:disable:next type_body_length
final class FamiliarSelectionTests: XCTestCase {
    func testCodexProfileDerivationRequiresSignedInProfile() {
        let pairing = daemonPairing(host: "Mac.Local", port: 7001)

        XCTAssertEqual(
            ChatFamiliarProfile.active(
                backend: .codex,
                codexProfileID: "profile-a",
                companionAvailability: .checking,
                previous: nil
            ),
            .codex(profileID: "profile-a")
        )
        XCTAssertNil(
            ChatFamiliarProfile.active(
                backend: .codex,
                codexProfileID: nil,
                companionAvailability: .ready(pairing),
                previous: nil
            )
        )
    }

    func testCompanionProfileDerivationPreservesCheckingAndSwitchesEndpoint() {
        let firstPairing = daemonPairing(host: "Mac.Local", port: 7001)
        let secondPairing = daemonPairing(host: "other.local", port: 7002)
        let companion = FamiliarProfileKey.companion(pairing: firstPairing)

        XCTAssertEqual(
            ChatFamiliarProfile.active(
                backend: .companionClaude,
                codexProfileID: nil,
                companionAvailability: .ready(firstPairing),
                previous: nil
            ),
            companion
        )
        XCTAssertEqual(
            ChatFamiliarProfile.active(
                backend: .companionClaude,
                codexProfileID: nil,
                companionAvailability: .checking,
                previous: companion
            ),
            companion
        )
        XCTAssertNil(
            ChatFamiliarProfile.active(
                backend: .companionClaude,
                codexProfileID: nil,
                companionAvailability: .idle,
                previous: companion
            )
        )
        XCTAssertNil(
            ChatFamiliarProfile.active(
                backend: .companionClaude,
                codexProfileID: nil,
                companionAvailability: .blocked(
                    reason: "Unavailable",
                    hint: "Retry."
                ),
                previous: companion
            )
        )
        XCTAssertEqual(
            ChatFamiliarProfile.active(
                backend: .companionClaude,
                codexProfileID: nil,
                companionAvailability: .ready(secondPairing),
                previous: companion
            ),
            .companion(host: "other.local", port: 7002)
        )
    }

    func testProfileSynchronizationRestoresPerProfileSelection() throws {
        try withDefaults { defaults in
            let store = FamiliarSelectionStore(defaults: defaults)
            let first = FamiliarProfileKey.codex(profileID: "profile-a")
            let second = FamiliarProfileKey.codex(profileID: "profile-b")
            try store.save(
                familiarIdentity(id: "sage", name: "Sage"),
                for: first
            )
            try store.save(
                familiarIdentity(id: "forge", name: "Forge"),
                for: second
            )
            let client = FakeFamiliarRosterClient(gate: .notPaired)
            let model = FamiliarSelectionModel(client: client, store: store)

            XCTAssertEqual(
                ChatFamiliarProfile.synchronize(first, model: model),
                "sage"
            )
            XCTAssertEqual(model.activeProfile, first)
            XCTAssertEqual(
                ChatFamiliarProfile.synchronize(second, model: model),
                "forge"
            )
            XCTAssertEqual(model.activeProfile, second)
        }
    }

    func testCodexResumeSettingsSynchronizeProfileBeforeCapture() throws {
        try withDefaults { defaults in
            let store = FamiliarSelectionStore(defaults: defaults)
            let companion = FamiliarProfileKey.companion(
                host: "mac.local",
                port: 7001
            )
            let codex = FamiliarProfileKey.codex(profileID: "profile-a")
            let owl = familiarIdentity(id: "owl", name: "Owl")
            let forge = familiarIdentity(id: "forge", name: "Forge")
            try store.save(owl, for: companion)
            try store.save(forge, for: codex)
            let model = FamiliarSelectionModel(
                client: FakeFamiliarRosterClient(gate: .notPaired),
                store: store
            )
            model.activate(companion)
            let current = ChatSettings(
                backend: .companionClaude,
                model: "",
                daemonProjectRoot: "/companion",
                familiarID: "owl"
            )

            let prepared = try XCTUnwrap(
                ChatFamiliarProfile.settingsForCodexResume(
                    current: current,
                    codexProfileID: "profile-a",
                    defaultModel: "codex-default",
                    model: model
                )
            )

            XCTAssertEqual(
                current,
                ChatSettings(
                    backend: .companionClaude,
                    model: "",
                    daemonProjectRoot: "/companion",
                    familiarID: "owl"
                )
            )
            XCTAssertEqual(prepared.backend, .codex)
            XCTAssertEqual(prepared.model, "codex-default")
            XCTAssertEqual(prepared.familiarID, "forge")
            XCTAssertEqual(model.activeProfile, codex)
            XCTAssertEqual(model.selectedFamiliar, forge)
            XCTAssertEqual(try store.load(for: companion), owl)
            XCTAssertEqual(try store.load(for: codex), forge)
        }
    }

    func testCodexResumeSettingsWithoutProfilePreserveCompanionState() throws {
        try withDefaults { defaults in
            let store = FamiliarSelectionStore(defaults: defaults)
            let companion = FamiliarProfileKey.companion(
                host: "mac.local",
                port: 7001
            )
            let owl = familiarIdentity(id: "owl", name: "Owl")
            try store.save(owl, for: companion)
            let model = FamiliarSelectionModel(
                client: FakeFamiliarRosterClient(gate: .notPaired),
                store: store
            )
            model.activate(companion)
            let current = ChatSettings(
                backend: .companionClaude,
                model: "",
                daemonProjectRoot: "/companion",
                familiarID: "owl"
            )

            XCTAssertNil(
                ChatFamiliarProfile.settingsForCodexResume(
                    current: current,
                    codexProfileID: nil,
                    defaultModel: "codex-default",
                    model: model
                )
            )
            XCTAssertEqual(model.activeProfile, companion)
            XCTAssertEqual(model.selectedFamiliar, owl)
            XCTAssertEqual(try store.load(for: companion), owl)
        }
    }

    func testSameProfileSyncPreservesPinnedLiveSessionSetting() throws {
        try withDefaults { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "profile-a")
            let store = FamiliarSelectionStore(defaults: defaults)
            try store.save(
                familiarIdentity(id: "forge", name: "Forge"),
                for: profile
            )
            let model = FamiliarSelectionModel(
                client: FakeFamiliarRosterClient(gate: .notPaired),
                store: store
            )
            model.activate(profile)

            XCTAssertEqual(
                ChatFamiliarProfile.synchronize(
                    profile,
                    model: model,
                    currentFamiliarID: "sage",
                    preserveCurrent: true
                ),
                "sage"
            )

            let other = FamiliarProfileKey.codex(profileID: "profile-b")
            try store.save(
                familiarIdentity(id: "owl", name: "Owl"),
                for: other
            )
            XCTAssertEqual(
                ChatFamiliarProfile.synchronize(
                    other,
                    model: model,
                    currentFamiliarID: "sage",
                    preserveCurrent: true
                ),
                "sage"
            )
            XCTAssertEqual(model.activeProfile, other)
        }
    }

    func testFamiliarPresentationUsesLiteralIconEmojiAndFallback() {
        let literal = FamiliarPresentation(
            remote: remoteFamiliar(
                id: "literal",
                name: "Literal",
                role: "  Review  ",
                icon: "⌁"
            )
        )
        let emoji = FamiliarPresentation(
            remote: remoteFamiliar(
                id: "emoji",
                name: "Emoji",
                emoji: "🦉",
                icon: "ph:owl"
            )
        )
        let fallback = FamiliarPresentation(
            remote: remoteFamiliar(
                id: "fallback",
                name: "Fallback",
                role: " ",
                icon: "ph:sparkle"
            )
        )
        let remoteAsset = FamiliarPresentation(
            remote: remoteFamiliar(
                id: "remote",
                name: "Remote",
                icon: "https://example.invalid/icon.png"
            )
        )

        XCTAssertEqual(literal.glyph, "⌁")
        XCTAssertEqual(literal.role, "Review")
        XCTAssertEqual(emoji.glyph, "🦉")
        XCTAssertEqual(fallback.glyph, "✦")
        XCTAssertEqual(remoteAsset.glyph, "✦")
        XCTAssertNil(fallback.role)
    }

    func testPickerReconcilesUnknownSelectionToActualSelection() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "profile-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "sage", name: "Sage")
            ])
            let model = FamiliarSelectionModel(
                client: client,
                store: FamiliarSelectionStore(defaults: defaults)
            )
            model.activate(profile)
            await model.refresh()
            model.select(id: "sage", for: profile)
            var settings = ChatSettings(familiarID: "sage")

            FamiliarPickerSection.reconcileSelection(
                "removed",
                settings: &settings,
                model: model,
                profile: profile
            )

            XCTAssertEqual(settings.familiarID, "sage")
        }
    }

    func testPickerReconcilesStoreFailureToActualSelection() async throws {
        let suiteName = "familiar-corrupt-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            PersistentlyCorruptFamiliarDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = FamiliarProfileKey.codex(profileID: "profile-a")
        let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
        client.familiarResult = .success([
            remoteFamiliar(id: "forge", name: "Forge")
        ])
        let model = FamiliarSelectionModel(
            client: client,
            store: FamiliarSelectionStore(defaults: defaults)
        )
        model.activate(profile)
        await model.refresh()
        var settings = ChatSettings(familiarID: "stale")

        FamiliarPickerSection.reconcileSelection(
            "forge",
            settings: &settings,
            model: model,
            profile: profile
        )

        XCTAssertNil(settings.familiarID)
        XCTAssertEqual(
            model.state,
            .failed(reason: "Saved familiar selections could not be read.")
        )
    }

    func testCachedFailedRosterKeepsPickerSelectable() {
        XCTAssertFalse(
            FamiliarPickerSection.isPickerDisabled(
                profile: .codex(profileID: "profile-a"),
                roster: [remoteFamiliar(id: "sage", name: "Sage")],
                state: .failed(reason: "Offline")
            )
        )
        XCTAssertTrue(
            FamiliarPickerSection.isPickerDisabled(
                profile: .codex(profileID: "profile-a"),
                roster: [],
                state: .failed(reason: "Offline")
            )
        )
    }

    func testPickerIdleProfileExplainsPairedDaemonSource() {
        XCTAssertEqual(
            FamiliarPickerSection.idleExplanation(
                for: .codex(profileID: "profile-a")
            ),
            "Familiars come from your paired Coven daemon."
        )
        XCTAssertNil(FamiliarPickerSection.idleExplanation(for: nil))
    }

    func testPickerIdleLoadAndFailedRetryDelegateToInjectedAction() async throws {
        try await withDefaultsAsync { defaults in
            var refreshes = 0
            let profile = FamiliarProfileKey.codex(profileID: "profile-a")
            let model = FamiliarSelectionModel(
                client: FakeFamiliarRosterClient(gate: .notPaired),
                store: FamiliarSelectionStore(defaults: defaults)
            )
            model.activate(profile)
            let picker = FamiliarPickerSection(
                settings: .constant(ChatSettings()),
                model: model,
                profile: profile,
                refreshContext: {
                    refreshes += 1
                }
            )

            XCTAssertEqual(model.state, .idle)
            await picker.performRefresh()
            _ = await model.refresh()
            guard case .failed = model.state else {
                return XCTFail("expected failed state before retry")
            }
            await picker.performRefresh()

            XCTAssertEqual(refreshes, 2)
        }
    }

    func testPickerLoadAndRetryUseOnlyInjectedContextRefresh() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Views/FamiliarPickerSection.swift"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            source.components(
                separatedBy: "Task { await performRefresh() }"
            ).count - 1,
            2
        )
        XCTAssertFalse(source.contains("model.refresh()"))
    }

    func testIdentitySealKeepsActiveConversationAheadOfNextSelection() {
        let sage = familiarIdentity(
            id: "sage",
            name: "Sage",
            role: "Research"
        )
        let forge = familiarIdentity(
            id: "forge",
            name: "Forge",
            role: "Implementation"
        )

        let seal = FamiliarSealResolver.onDevice(
            activeFamiliar: sage,
            hasActiveSession: true,
            selectedFamiliar: forge,
            roster: []
        )

        XCTAssertEqual(seal?.displayName, "Sage")
        XCTAssertEqual(seal?.role, "Research")
        XCTAssertEqual(seal?.binding, .activeConversation)
    }

    func testResumedIdentitySealAndPickerKeepSeparateActiveAndNextValues() throws {
        try withDefaults { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "profile-a")
            let forge = familiarIdentity(id: "forge", name: "Forge")
            let store = FamiliarSelectionStore(defaults: defaults)
            try store.save(forge, for: profile)
            let model = FamiliarSelectionModel(
                client: FakeFamiliarRosterClient(gate: .notPaired),
                store: store
            )
            model.activate(profile)

            let pickerValue = ChatFamiliarProfile.synchronize(
                profile,
                model: model,
                currentFamiliarID: "forge",
                preserveCurrent: true
            )
            let seal = FamiliarSealResolver.onDevice(
                activeFamiliar: familiarIdentity(id: "sage", name: "Sage"),
                hasActiveSession: true,
                selectedFamiliar: model.selectedFamiliar,
                roster: []
            )

            XCTAssertEqual(pickerValue, "forge")
            XCTAssertEqual(model.selectedFamiliar, forge)
            XCTAssertEqual(seal?.displayName, "Sage")
            XCTAssertEqual(seal?.binding, .activeConversation)
        }
    }

    func testIdentitySealDoesNotUseNextSelectionForIdentityLessActiveConversation() {
        let seal = FamiliarSealResolver.onDevice(
            activeFamiliar: nil,
            hasActiveSession: true,
            selectedFamiliar: familiarIdentity(
                id: "forge",
                name: "Forge",
                role: "Implementation"
            ),
            roster: []
        )

        XCTAssertNil(seal)
    }

    func testIdentitySealUsesSelectionForNextConversation() {
        let seal = FamiliarSealResolver.onDevice(
            activeFamiliar: nil,
            hasActiveSession: false,
            selectedFamiliar: familiarIdentity(
                id: "forge",
                name: "Forge",
                role: "Implementation"
            ),
            roster: []
        )

        XCTAssertEqual(seal?.displayName, "Forge")
        XCTAssertEqual(seal?.role, "Implementation")
        XCTAssertEqual(seal?.binding, .nextSession)
    }

    func testCompanionIdentitySealFallsBackToBoundID() {
        let seal = FamiliarSealResolver.companion(
            activeFamiliar: familiarIdentity(
                id: "archived-familiar",
                name: "archived-familiar"
            ),
            hasActiveSession: true,
            selectedFamiliar: nil,
            roster: []
        )

        XCTAssertEqual(seal?.displayName, "archived-familiar")
        XCTAssertEqual(seal?.glyph, "✦")
        XCTAssertEqual(seal?.binding, .activeConversation)
    }

    func testCompanionIdentitySealDoesNotUseNextSelectionForIdentityLessActiveConversation() {
        let seal = FamiliarSealResolver.companion(
            activeFamiliar: nil,
            hasActiveSession: true,
            selectedFamiliar: familiarIdentity(
                id: "forge",
                name: "Forge",
                role: "Implementation"
            ),
            roster: []
        )

        XCTAssertNil(seal)
    }

    func testCompanionIdentitySealUsesSelectionForNextConversation() {
        let seal = FamiliarSealResolver.companion(
            activeFamiliar: nil,
            hasActiveSession: false,
            selectedFamiliar: familiarIdentity(
                id: "forge",
                name: "Forge",
                role: "Implementation"
            ),
            roster: []
        )

        XCTAssertEqual(seal?.displayName, "Forge")
        XCTAssertEqual(seal?.role, "Implementation")
        XCTAssertEqual(seal?.binding, .nextSession)
    }

    func testCompanionActiveSealNeverConsultsCurrentRoster() {
        let seal = FamiliarSealResolver.companion(
            activeFamiliar: familiarIdentity(
                id: "sage",
                name: "Sage on A",
                emoji: "🅰️",
                role: "A role"
            ),
            hasActiveSession: true,
            selectedFamiliar: familiarIdentity(
                id: "sage",
                name: "Sage on B",
                emoji: "🅱️",
                role: "B role"
            ),
            roster: [
                remoteFamiliar(
                    id: "sage",
                    name: "Sage on B",
                    emoji: "🅱️",
                    role: "B role"
                )
            ]
        )

        XCTAssertEqual(seal?.displayName, "Sage on A")
        XCTAssertEqual(seal?.glyph, "🅰️")
        XCTAssertEqual(seal?.role, "A role")
        XCTAssertEqual(seal?.binding, .activeConversation)
    }

    func testRefreshCoordinatorStopsBeforeRosterForStaleAvailability() async {
        var synchronizations = 0
        var rosterRefreshes = 0
        var finalSynchronizations = 0

        let published = await FamiliarContextRefreshCoordinator.refresh(
            availability: { false },
            synchronizeAfterAvailability: { synchronizations += 1 },
            roster: {
                rosterRefreshes += 1
                return true
            },
            synchronizeAfterRoster: { finalSynchronizations += 1 }
        )

        XCTAssertFalse(published)
        XCTAssertEqual(synchronizations, 0)
        XCTAssertEqual(rosterRefreshes, 0)
        XCTAssertEqual(finalSynchronizations, 0)
    }

    func testRefreshCoordinatorStopsWhenCancelledAfterAvailability() async {
        var synchronizations = 0
        var rosterRefreshes = 0

        let pipeline = Task {
            await FamiliarContextRefreshCoordinator.refresh(
                availability: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                },
                synchronizeAfterAvailability: { synchronizations += 1 },
                roster: {
                    rosterRefreshes += 1
                    return true
                },
                synchronizeAfterRoster: {}
            )
        }
        let published = await pipeline.value

        XCTAssertFalse(published)
        XCTAssertEqual(synchronizations, 0)
        XCTAssertEqual(rosterRefreshes, 0)
    }

    func testRefreshCoordinatorStopsBeforeFinalSyncForStaleRoster() async {
        var synchronizations = 0
        var rosterRefreshes = 0
        var finalSynchronizations = 0

        let published = await FamiliarContextRefreshCoordinator.refresh(
            availability: { true },
            synchronizeAfterAvailability: { synchronizations += 1 },
            roster: {
                rosterRefreshes += 1
                return false
            },
            synchronizeAfterRoster: { finalSynchronizations += 1 }
        )

        XCTAssertFalse(published)
        XCTAssertEqual(synchronizations, 1)
        XCTAssertEqual(rosterRefreshes, 1)
        XCTAssertEqual(finalSynchronizations, 0)
    }

    func testRefreshCoordinatorStopsWhenCancelledAfterRoster() async {
        var finalSynchronizations = 0

        let pipeline = Task {
            await FamiliarContextRefreshCoordinator.refresh(
                availability: { true },
                synchronizeAfterAvailability: {},
                roster: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                },
                synchronizeAfterRoster: { finalSynchronizations += 1 }
            )
        }
        let published = await pipeline.value

        XCTAssertFalse(published)
        XCTAssertEqual(finalSynchronizations, 0)
    }

    // swiftlint:disable:next function_body_length
    func testNewerRefreshCoordinatorPipelineWinsDeterministically() async {
        let firstAvailabilityRequested = XCTestExpectation(
            description: "first availability requested"
        )
        let secondRosterRequested = XCTestExpectation(
            description: "second roster requested"
        )
        var firstAvailabilityContinuation: CheckedContinuation<Bool, Never>?
        var secondRosterContinuation: CheckedContinuation<Bool, Never>?
        var firstRosterRefreshes = 0
        var firstFinalSynchronizations = 0
        var secondSynchronizations = 0
        var secondFinalSynchronizations = 0

        let first = Task {
            await FamiliarContextRefreshCoordinator.refresh(
                availability: {
                    firstAvailabilityRequested.fulfill()
                    return await withCheckedContinuation { continuation in
                        firstAvailabilityContinuation = continuation
                    }
                },
                synchronizeAfterAvailability: {},
                roster: {
                    firstRosterRefreshes += 1
                    return true
                },
                synchronizeAfterRoster: {
                    firstFinalSynchronizations += 1
                }
            )
        }
        await fulfillment(of: [firstAvailabilityRequested], timeout: 1)

        let second = Task {
            await FamiliarContextRefreshCoordinator.refresh(
                availability: { true },
                synchronizeAfterAvailability: {
                    secondSynchronizations += 1
                },
                roster: {
                    secondRosterRequested.fulfill()
                    return await withCheckedContinuation { continuation in
                        secondRosterContinuation = continuation
                    }
                },
                synchronizeAfterRoster: {
                    secondFinalSynchronizations += 1
                }
            )
        }
        await fulfillment(of: [secondRosterRequested], timeout: 1)

        secondRosterContinuation?.resume(returning: true)
        let secondPublished = await second.value
        firstAvailabilityContinuation?.resume(returning: false)
        let firstPublished = await first.value

        XCTAssertTrue(secondPublished)
        XCTAssertFalse(firstPublished)
        XCTAssertEqual(firstRosterRefreshes, 0)
        XCTAssertEqual(firstFinalSynchronizations, 0)
        XCTAssertEqual(secondSynchronizations, 1)
        XCTAssertEqual(secondFinalSynchronizations, 1)
    }

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
                for: .companion(host: " Mac.Tailnet.TS.NET ", port: 49152)
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

    func testOlderCancelledRefreshCannotRestoreOverNewerEndpoint() async throws {
        try await withDefaultsAsync { defaults in
            let endpointA = daemonPairing(host: "a.local", port: 7001)
            let endpointB = daemonPairing(host: "b.local", port: 7002)
            let client = FakeFamiliarRosterClient(gate: .ready(endpointA))
            client.suspendsGate = true
            client.suspendsFamiliars = true
            let model = makeModel(defaults: defaults, client: client)
            model.activate(.companion(host: endpointA.host, port: endpointA.port))

            let firstGate = client.expectGate("endpoint A gate requested")
            let firstFamiliars = client.expectFamiliars("endpoint A roster requested")
            let firstRefresh = Task { await model.refresh() }
            await fulfillment(of: [firstGate], timeout: 1)
            client.resumeNextGate(with: .ready(endpointA))
            await fulfillment(of: [firstFamiliars], timeout: 1)

            let secondGate = client.expectGate("endpoint B gate requested")
            let secondFamiliars = client.expectFamiliars("endpoint B roster requested")
            let secondRefresh = Task { await model.refresh() }
            await fulfillment(of: [secondGate], timeout: 1)
            client.resumeNextGate(with: .ready(endpointB))
            await fulfillment(of: [secondFamiliars], timeout: 1)
            firstRefresh.cancel()
            client.resumeLastFamiliars(
                returning: [remoteFamiliar(id: "b", name: "B Familiar")]
            )
            let secondPublished = await secondRefresh.value

            client.resumeNextFamiliars(
                returning: [remoteFamiliar(id: "a", name: "A Familiar")]
            )
            let firstPublished = await firstRefresh.value

            XCTAssertTrue(secondPublished)
            XCTAssertFalse(firstPublished)
            XCTAssertEqual(model.companionProfile, .companion(host: "b.local", port: 7002))
            XCTAssertEqual(model.activeProfile, .companion(host: "b.local", port: 7002))
            XCTAssertEqual(model.roster.map(\.id), ["b"])
            XCTAssertEqual(model.state, .loaded)
        }
    }

    func testOlderRosterPipelineSkipsFinalSyncWhileNewerPipelineWins() async throws {
        try await withDefaultsAsync { defaults in
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.suspendsFamiliars = true
            let model = makeModel(defaults: defaults, client: client)
            model.activate(.codex(profileID: "codex-a"))
            var firstFinalSynchronizations = 0
            var secondFinalSynchronizations = 0

            let firstRoster = client.expectFamiliars("first roster requested")
            let first = Task {
                await FamiliarContextRefreshCoordinator.refresh(
                    availability: { true },
                    synchronizeAfterAvailability: {},
                    roster: { await model.refresh() },
                    synchronizeAfterRoster: {
                        firstFinalSynchronizations += 1
                    }
                )
            }
            await fulfillment(of: [firstRoster], timeout: 1)

            let secondRoster = client.expectFamiliars("second roster requested")
            let second = Task {
                await FamiliarContextRefreshCoordinator.refresh(
                    availability: { true },
                    synchronizeAfterAvailability: {},
                    roster: { await model.refresh() },
                    synchronizeAfterRoster: {
                        secondFinalSynchronizations += 1
                    }
                )
            }
            await fulfillment(of: [secondRoster], timeout: 1)

            client.resumeLastFamiliars(
                returning: [remoteFamiliar(id: "new", name: "New")]
            )
            let secondPublished = await second.value
            client.resumeNextFamiliars(
                returning: [remoteFamiliar(id: "old", name: "Old")]
            )
            let firstPublished = await first.value

            XCTAssertTrue(secondPublished)
            XCTAssertFalse(firstPublished)
            XCTAssertEqual(firstFinalSynchronizations, 0)
            XCTAssertEqual(secondFinalSynchronizations, 1)
            XCTAssertEqual(model.roster.map(\.id), ["new"])
        }
    }

    func testCancelledRosterRefreshRestoresLoadedContext() async throws {
        try await withDefaultsAsync { defaults in
            let endpointA = daemonPairing(host: "a.local", port: 7001)
            let endpointB = daemonPairing(host: "b.local", port: 7002)
            let profileA = FamiliarProfileKey.companion(pairing: endpointA)
            let client = FakeFamiliarRosterClient(gate: .ready(endpointA))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven"),
                remoteFamiliar(id: "owl", name: "Owl")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profileA)
            await model.refresh()
            model.select(id: "raven", for: profileA)

            client.gateResult = .ready(endpointB)
            client.suspendsFamiliars = true

            let requested = client.expectFamiliars()
            let refresh = Task { await model.refresh() }
            await fulfillment(of: [requested], timeout: 1)

            refresh.cancel()
            client.resumeNextFamiliars(
                returning: [remoteFamiliar(id: "raven", name: "Raven")]
            )

            let published = await refresh.value
            XCTAssertFalse(published)
            XCTAssertEqual(model.state, .loaded)
            XCTAssertEqual(model.roster.map(\.id), ["owl", "raven"])
            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(model.activeProfile, profileA)
            XCTAssertEqual(model.companionProfile, profileA)
        }
    }

    func testCancelledRosterRefreshRestoresFailedContextAndProvenance() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven"),
                remoteFamiliar(id: "owl", name: "Owl")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()
            model.select(id: "raven", for: profile)
            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            await model.refresh()

            client.suspendsFamiliars = true
            let requested = client.expectFamiliars()
            let refresh = Task { await model.refresh() }
            await fulfillment(of: [requested], timeout: 1)

            refresh.cancel()
            client.resumeNextFamiliars(
                returning: [remoteFamiliar(id: "changed", name: "Changed")]
            )
            let published = await refresh.value

            XCTAssertFalse(published)
            XCTAssertEqual(
                model.state,
                .failed(reason: "Roster transport failed.")
            )
            XCTAssertEqual(model.roster.map(\.id), ["owl", "raven"])
            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(model.activeProfile, profile)
            XCTAssertEqual(
                model.companionProfile,
                .companion(pairing: daemonPairing())
            )

            model.select(id: "owl", for: profile)
            XCTAssertEqual(model.selectedFamiliar?.id, "owl")
            XCTAssertEqual(
                model.state,
                .failed(reason: "Roster transport failed.")
            )
        }
    }

    func testRosterRefreshCancelledBeforeStartLeavesContextUnchanged() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()
            model.select(id: "raven", for: profile)
            let priorGateCalls = client.gateCallCount

            let refresh = Task { await model.refresh() }
            refresh.cancel()
            let published = await refresh.value

            XCTAssertFalse(published)
            XCTAssertEqual(client.gateCallCount, priorGateCalls)
            XCTAssertEqual(model.state, .loaded)
            XCTAssertEqual(model.roster.map(\.id), ["raven"])
            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(model.activeProfile, profile)
            XCTAssertEqual(
                model.companionProfile,
                .companion(pairing: daemonPairing())
            )
        }
    }

    func testCancelledNewerRosterRefreshRestoresLastStableContext() async throws {
        try await withDefaultsAsync { defaults in
            let endpointA = daemonPairing(host: "a.local", port: 7001)
            let endpointB = daemonPairing(host: "b.local", port: 7002)
            let profileA = FamiliarProfileKey.companion(pairing: endpointA)
            let client = FakeFamiliarRosterClient(gate: .ready(endpointA))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profileA)
            await model.refresh()
            model.select(id: "raven", for: profileA)

            client.gateResult = .ready(endpointB)
            client.suspendsFamiliars = true
            let firstRequested = client.expectFamiliars(
                "older endpoint B roster requested"
            )
            let first = Task { await model.refresh() }
            await fulfillment(of: [firstRequested], timeout: 1)
            let secondRequested = client.expectFamiliars(
                "newer endpoint B roster requested"
            )
            let second = Task { await model.refresh() }
            await fulfillment(of: [secondRequested], timeout: 1)

            second.cancel()
            client.resumeLastFamiliars(
                returning: [remoteFamiliar(id: "b", name: "B Familiar")]
            )
            let secondPublished = await second.value
            client.resumeNextFamiliars(
                returning: [remoteFamiliar(id: "stale", name: "Stale")]
            )
            let firstPublished = await first.value

            XCTAssertFalse(secondPublished)
            XCTAssertFalse(firstPublished)
            XCTAssertEqual(model.state, .loaded)
            XCTAssertEqual(model.roster.map(\.id), ["raven"])
            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(model.activeProfile, profileA)
            XCTAssertEqual(model.companionProfile, profileA)
        }
    }

    func testSelectionWhileRefreshSuspendedInvalidatesStaleCompletion() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "old", name: "Old"),
                remoteFamiliar(id: "new", name: "New")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()
            model.select(id: "old", for: profile)

            client.suspendsFamiliars = true
            let requested = client.expectFamiliars()
            let refresh = Task { await model.refresh() }
            await fulfillment(of: [requested], timeout: 1)

            model.select(id: "NEW", for: profile)
            refresh.cancel()
            client.resumeNextFamiliars(
                returning: [remoteFamiliar(id: "old", name: "Changed")]
            )
            await refresh.value

            XCTAssertEqual(model.selectedFamiliar?.id, "new")
            XCTAssertEqual(model.roster.map(\.id), ["new", "old"])
            XCTAssertEqual(try model.selection(for: profile)?.id, "new")
        }
    }

    func testSuccessfulRefreshClearsRemovedSelectionAndPersistsNil() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let store = FamiliarSelectionStore(defaults: defaults)
            try store.save(
                familiarIdentity(id: "raven", name: "Raven"),
                for: profile
            )
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "owl", name: "Owl")
            ])
            let model = FamiliarSelectionModel(client: client, store: store)

            model.activate(profile)
            await model.refresh()

            XCTAssertNil(model.selectedFamiliar)
            XCTAssertNil(try store.load(for: profile))
            XCTAssertEqual(model.state, .loaded)
        }
    }

    func testSuccessfulRefreshUpdatesStoredSnapshotFromDaemon() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let store = FamiliarSelectionStore(defaults: defaults)
            try store.save(
                familiarIdentity(
                    id: "raven",
                    name: "Old Raven",
                    emoji: "x",
                    role: "Old role"
                ),
                for: profile
            )
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(
                    id: "RAVEN",
                    name: "The Raven",
                    emoji: "🐦‍⬛",
                    role: "Research"
                )
            ])
            let model = FamiliarSelectionModel(client: client, store: store)

            model.activate(profile)
            await model.refresh()

            let selected = try XCTUnwrap(model.selectedFamiliar)
            XCTAssertEqual(selected.id, "RAVEN")
            XCTAssertEqual(selected.displayName, "The Raven")
            XCTAssertEqual(selected.emoji, "🐦‍⬛")
            XCTAssertEqual(selected.role, "Research")
            XCTAssertEqual(try store.load(for: profile), selected)
        }
    }

    func testTransportFailureRetainsCachedRosterAndSelection() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "The Raven")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()
            model.select(id: "raven", for: profile)

            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            let published = await model.refresh()

            XCTAssertTrue(published)
            XCTAssertEqual(model.roster.map(\.id), ["raven"])
            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(
                model.state,
                .failed(reason: "Roster transport failed.")
            )
        }
    }

    func testTransportFailureRemainsVisibleAfterSelectingCachedFamiliar() async throws {
        try await withDefaultsAsync { defaults in
            let pairing = daemonPairing(host: "mac.local", port: 7001)
            let profile = FamiliarProfileKey.companion(
                host: pairing.host,
                port: pairing.port
            )
            let client = FakeFamiliarRosterClient(gate: .ready(pairing))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven"),
                remoteFamiliar(id: "owl", name: "Owl")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()
            model.select(id: "raven", for: profile)

            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            await model.refresh()
            model.select(
                id: "owl",
                for: .companion(host: " MAC.LOCAL ", port: 7001)
            )

            XCTAssertEqual(model.activeProfile, profile)
            XCTAssertEqual(model.selectedFamiliar?.id, "owl")
            XCTAssertEqual(try model.selection(for: profile)?.id, "owl")
            XCTAssertEqual(
                model.state,
                .failed(reason: "Roster transport failed.")
            )
        }
    }

    func testTransportFailureRemainsVisibleAfterClearingSelection() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()
            model.select(id: "raven", for: profile)

            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            await model.refresh()
            model.select(id: nil, for: profile)

            XCTAssertNil(model.selectedFamiliar)
            XCTAssertNil(try model.selection(for: profile))
            XCTAssertEqual(
                model.state,
                .failed(reason: "Roster transport failed.")
            )
        }
    }

    func testUnavailableGateFailuresSurviveSelectionAndClear() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven"),
                remoteFamiliar(id: "owl", name: "Owl")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()
            model.select(id: "raven", for: profile)

            client.gateResult = .notPaired
            await model.refresh()
            model.select(id: "owl", for: profile)

            XCTAssertEqual(model.selectedFamiliar?.id, "owl")
            XCTAssertEqual(
                model.state,
                .failed(reason: "Pair with a daemon to load familiars.")
            )

            client.gateResult = .blocked(
                reason: "Daemon unavailable",
                hint: "Reconnect the tunnel."
            )
            await model.refresh()
            model.select(id: nil, for: profile)

            XCTAssertNil(model.selectedFamiliar)
            XCTAssertNil(try model.selection(for: profile))
            XCTAssertEqual(
                model.state,
                .failed(
                    reason: "Daemon unavailable Reconnect the tunnel."
                )
            )
        }
    }

    func testSelectionForDifferentProfileDoesNotInheritRefreshFailure() async throws {
        try await withDefaultsAsync { defaults in
            let firstProfile = FamiliarProfileKey.codex(profileID: "codex-a")
            let secondProfile = FamiliarProfileKey.codex(profileID: "codex-b")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(firstProfile)
            await model.refresh()

            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            await model.refresh()
            model.select(id: "raven", for: secondProfile)

            XCTAssertEqual(model.activeProfile, secondProfile)
            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(try model.selection(for: secondProfile)?.id, "raven")
            XCTAssertEqual(model.state, .loaded)
        }
    }

    func testSuccessfulRefreshClearsFailureAfterCachedSelection() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven"),
                remoteFamiliar(id: "owl", name: "Owl")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()

            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            await model.refresh()
            model.select(id: "owl", for: profile)
            XCTAssertEqual(
                model.state,
                .failed(reason: "Roster transport failed.")
            )

            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven"),
                remoteFamiliar(id: "owl", name: "Updated Owl")
            ])
            await model.refresh()

            XCTAssertEqual(model.state, .loaded)
            XCTAssertEqual(model.selectedFamiliar?.displayName, "Updated Owl")
            XCTAssertEqual(
                try model.selection(for: profile)?.displayName,
                "Updated Owl"
            )
        }
    }

    func testUnavailableGatesRetainCachedSelectionWithActionableFailure() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "The Raven")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()
            model.select(id: "raven", for: profile)

            client.gateResult = .notPaired
            await model.refresh()
            XCTAssertEqual(
                model.state,
                .failed(reason: "Pair with a daemon to load familiars.")
            )
            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(model.roster.map(\.id), ["raven"])

            client.gateResult = .blocked(
                reason: "Daemon unavailable",
                hint: "Reconnect the tunnel."
            )
            await model.refresh()
            guard case let .failed(reason) = model.state else {
                return XCTFail("expected blocked failure")
            }
            XCTAssertTrue(reason.contains("Daemon unavailable"))
            XCTAssertTrue(reason.contains("Reconnect the tunnel."))
            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(model.roster.map(\.id), ["raven"])
        }
    }

    func testDaemonRestartPreservesEndpointCacheAndSelection() async throws {
        try await withDefaultsAsync { defaults in
            let firstPairing = daemonPairing(
                host: "Mac.Local",
                port: 7001,
                pid: 10,
                startedAt: "first"
            )
            let client = FakeFamiliarRosterClient(gate: .ready(firstPairing))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "The Raven")
            ])
            let model = makeModel(defaults: defaults, client: client)
            let profile = FamiliarProfileKey.companion(
                host: "mac.local",
                port: 7001
            )
            model.activate(profile)
            await model.refresh()
            model.select(id: "raven", for: profile)

            client.gateResult = .ready(
                daemonPairing(
                    host: " MAC.LOCAL ",
                    port: 7001,
                    pid: 99,
                    startedAt: "second"
                )
            )
            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            await model.refresh()

            XCTAssertEqual(model.companionProfile, profile)
            XCTAssertEqual(model.activeProfile, profile)
            XCTAssertEqual(model.roster.map(\.id), ["raven"])
            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(try model.selection(for: profile)?.id, "raven")
        }
    }

    func testDifferentEndpointIsolatesCacheAndPersistedSelection() async throws {
        try await withDefaultsAsync { defaults in
            let endpointA = daemonPairing(host: "a.local", port: 7001)
            let endpointB = daemonPairing(host: "b.local", port: 7002)
            let profileA = FamiliarProfileKey.companion(
                host: endpointA.host,
                port: endpointA.port
            )
            let profileB = FamiliarProfileKey.companion(
                host: endpointB.host,
                port: endpointB.port
            )
            let client = FakeFamiliarRosterClient(gate: .ready(endpointA))
            client.familiarResult = .success([
                remoteFamiliar(id: "a", name: "A Familiar")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profileA)
            await model.refresh()
            model.select(id: "a", for: profileA)

            client.gateResult = .ready(endpointB)
            client.familiarResult = .success([
                remoteFamiliar(id: "b", name: "B Familiar")
            ])
            await model.refresh()

            XCTAssertEqual(model.activeProfile, profileB)
            XCTAssertEqual(model.roster.map(\.id), ["b"])
            XCTAssertNil(model.selectedFamiliar)
            XCTAssertEqual(try model.selection(for: profileA)?.id, "a")
            XCTAssertNil(try model.selection(for: profileB))

            model.select(id: "b", for: profileB)
            XCTAssertEqual(try model.selection(for: profileB)?.id, "b")

            client.gateResult = .ready(endpointA)
            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            await model.refresh()

            XCTAssertEqual(model.activeProfile, profileA)
            XCTAssertEqual(model.roster.map(\.id), ["a"])
            XCTAssertEqual(model.selectedFamiliar?.id, "a")
        }
    }

    func testCodexProfilesShareLatestRosterButPersistSelectionsIndependently() async throws {
        try await withDefaultsAsync { defaults in
            let firstProfile = FamiliarProfileKey.codex(profileID: "codex-a")
            let secondProfile = FamiliarProfileKey.codex(profileID: "codex-b")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven"),
                remoteFamiliar(id: "owl", name: "Owl")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(firstProfile)
            await model.refresh()
            model.select(id: "raven", for: firstProfile)

            model.activate(secondProfile)
            XCTAssertEqual(model.roster.map(\.id), ["owl", "raven"])
            XCTAssertNil(model.selectedFamiliar)
            model.select(id: "owl", for: secondProfile)

            client.gateResult = .notPaired
            model.activate(firstProfile)
            await model.refresh()

            XCTAssertEqual(model.roster.map(\.id), ["owl", "raven"])
            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(try model.selection(for: secondProfile)?.id, "owl")
        }
    }

    func testUnknownSelectionFailsWithoutMutatingPriorSelection() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()
            model.select(id: "raven", for: profile)

            model.select(id: "removed", for: profile)

            XCTAssertEqual(
                model.state,
                .failed(reason: "The selected familiar is no longer available.")
            )
            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(try model.selection(for: profile)?.id, "raven")
            XCTAssertEqual(model.remoteFamiliar(for: "RAVEN")?.id, "raven")
        }
    }

    func testUnknownSelectionTakesPrecedenceOverRefreshFailure() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()

            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            await model.refresh()
            model.select(id: "removed", for: profile)

            XCTAssertEqual(
                model.state,
                .failed(reason: "The selected familiar is no longer available.")
            )
        }
    }

    func testSuccessfulSelectionRepairsStoreFailureWithoutHidingRefreshFailure() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "raven", name: "Raven")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()

            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            await model.refresh()
            defaults.set(
                Data([0xFF]),
                forKey: FamiliarSelectionStore.storageKey
            )

            model.select(id: "raven", for: profile)

            XCTAssertEqual(model.selectedFamiliar?.id, "raven")
            XCTAssertEqual(try model.selection(for: profile)?.id, "raven")
            XCTAssertEqual(
                model.state,
                .failed(reason: "Roster transport failed.")
            )
        }
    }

    func testRosterSortIsDeterministicAndEmptySuccessProvesRemoval() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .success([
                remoteFamiliar(id: "z-id", name: "beta"),
                remoteFamiliar(id: "b-id", name: "Alpha"),
                remoteFamiliar(id: "a-id", name: "alpha")
            ])
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            await model.refresh()

            XCTAssertEqual(model.roster.map(\.id), ["a-id", "b-id", "z-id"])
            model.select(id: "a-id", for: profile)

            client.familiarResult = .success([])
            await model.refresh()

            XCTAssertTrue(model.roster.isEmpty)
            XCTAssertNil(model.selectedFamiliar)
            XCTAssertNil(try model.selection(for: profile))
            XCTAssertEqual(model.state, .loaded)
        }
    }

    func testStoreCorruptionOnActivateIsVisibleAndBeatsTransportFailure() async throws {
        try await withDefaultsAsync { defaults in
            defaults.set(
                Data([0xFF]),
                forKey: FamiliarSelectionStore.storageKey
            )
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            let model = makeModel(defaults: defaults, client: client)

            model.activate(profile)
            XCTAssertEqual(
                model.state,
                .failed(reason: "Saved familiar selections could not be read.")
            )

            await model.refresh()

            XCTAssertEqual(
                model.state,
                .failed(reason: "Saved familiar selections could not be read.")
            )
        }
    }

    func testStoreCorruptionDuringRefreshIsVisibleAndBeatsTransportFailure() async throws {
        try await withDefaultsAsync { defaults in
            let profile = FamiliarProfileKey.codex(profileID: "codex-a")
            let client = FakeFamiliarRosterClient(gate: .ready(daemonPairing()))
            client.familiarResult = .failure(FakeFamiliarRosterError.transport)
            let model = makeModel(defaults: defaults, client: client)
            model.activate(profile)
            defaults.set(
                Data(#"{"version":99,"selections":{}}"#.utf8),
                forKey: FamiliarSelectionStore.storageKey
            )

            await model.refresh()

            XCTAssertEqual(
                model.state,
                .failed(reason: "Saved familiar selections could not be read.")
            )
        }
    }

    private func makeModel(
        defaults: UserDefaults,
        client: FakeFamiliarRosterClient
    ) -> FamiliarSelectionModel {
        FamiliarSelectionModel(
            client: client,
            store: FamiliarSelectionStore(defaults: defaults)
        )
    }

    private func withDefaults(
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let suiteName = "familiar-selection-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func withDefaultsAsync(
        _ body: (UserDefaults) async throws -> Void
    ) async throws {
        let suiteName = "familiar-selection-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(defaults)
    }
}

private func daemonPairing(
    host: String = "mac.local",
    port: UInt16 = 7777,
    pid: UInt32 = 42,
    startedAt: String = "now"
) -> DaemonPairing {
    DaemonPairing(
        host: host,
        port: port,
        apiVersion: "coven.daemon.v1",
        covenVersion: "0.7.0",
        pid: pid,
        startedAt: startedAt,
        pairedAt: Date()
    )
}

private func remoteFamiliar(
    id: String,
    name: String,
    emoji: String? = nil,
    role: String? = nil,
    icon: String? = nil
) -> RemoteFamiliar {
    RemoteFamiliar(
        id: id,
        displayName: name,
        emoji: emoji,
        role: role,
        description: nil,
        pronouns: nil,
        icon: icon
    )
}

private func familiarIdentity(
    id: String,
    name: String,
    emoji: String? = nil,
    role: String? = nil
) -> FamiliarIdentity {
    FamiliarIdentity(
        id: id,
        displayName: name,
        emoji: emoji,
        role: role
    )
}
