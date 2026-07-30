import Foundation

// swiftlint:disable file_length

enum FamiliarProfileKey: Hashable {
    case codex(profileID: String)
    case companion(host: String, port: UInt16)

    var storageValue: String {
        switch self {
        case let .codex(profileID):
            return "codex:\(profileID)"
        case let .companion(host, port):
            return "companion:\(Self.normalized(host: host)):\(port)"
        }
    }

    var normalized: FamiliarProfileKey {
        switch self {
        case .codex:
            return self
        case let .companion(host, port):
            return .companion(host: Self.normalized(host: host), port: port)
        }
    }

    static func companion(pairing: DaemonPairing) -> FamiliarProfileKey {
        .companion(
            host: normalized(host: pairing.host),
            port: pairing.port
        )
    }

    private static func normalized(host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

@MainActor
enum FamiliarContextRefreshCoordinator {
    @discardableResult
    static func refresh(
        availability: () async -> Bool,
        synchronizeAfterAvailability: () -> Void,
        roster: () async -> Bool,
        synchronizeAfterRoster: () -> Void
    ) async -> Bool {
        guard await availability() else { return false }
        guard !Task.isCancelled else { return false }
        synchronizeAfterAvailability()
        guard !Task.isCancelled else { return false }
        guard await roster() else { return false }
        guard !Task.isCancelled else { return false }
        synchronizeAfterRoster()
        return true
    }
}

@MainActor
protocol FamiliarRosterClient: AnyObject {
    func gate() async -> CompanionModel.SessionGate
    func familiars(pairing: DaemonPairing) async throws -> [RemoteFamiliar]
}

@MainActor
final class LiveFamiliarRosterClient: FamiliarRosterClient {
    private let companion: CompanionModel

    init(companion: CompanionModel) {
        self.companion = companion
    }

    func gate() async -> CompanionModel.SessionGate {
        companion.reloadPairing()
        return await companion.gateForSessionTraffic()
    }

    func familiars(pairing: DaemonPairing) async throws -> [RemoteFamiliar] {
        try await companion.engine.remoteFamiliars(
            host: pairing.host,
            port: pairing.port,
            timeoutMs: CompanionChatModel.requestTimeoutMs
        )
    }
}

@MainActor
// swiftlint:disable:next type_body_length
final class FamiliarSelectionModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(reason: String)
    }

    private struct RefreshFailure {
        let profile: FamiliarProfileKey
        let reason: String
    }

    private struct RefreshSnapshot {
        let roster: [RemoteFamiliar]
        let state: State
        let selectedFamiliar: FamiliarIdentity?
        let activeProfile: FamiliarProfileKey?
        let companionProfile: FamiliarProfileKey?
        let endpointRosterCache: [FamiliarProfileKey: [RemoteFamiliar]]
        let latestValidatedRoster: [RemoteFamiliar]?
        let storeFailureReason: String?
        let lastRefreshFailure: RefreshFailure?
    }

    @Published private(set) var roster: [RemoteFamiliar] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var selectedFamiliar: FamiliarIdentity?

    private(set) var activeProfile: FamiliarProfileKey?
    private(set) var companionProfile: FamiliarProfileKey?

    private let client: any FamiliarRosterClient
    private let store: FamiliarSelectionStore
    private var generation: UInt64 = 0
    private var endpointRosterCache: [
        FamiliarProfileKey: [RemoteFamiliar]
    ] = [:]
    private var latestValidatedRoster: [RemoteFamiliar]?
    private var storeFailureReason: String?
    private var lastRefreshFailure: RefreshFailure?
    private var refreshSnapshotInFlight: RefreshSnapshot?

    init(
        client: any FamiliarRosterClient,
        store: FamiliarSelectionStore = FamiliarSelectionStore()
    ) {
        self.client = client
        self.store = store
    }

    convenience init(
        companion: CompanionModel,
        store: FamiliarSelectionStore = FamiliarSelectionStore()
    ) {
        self.init(
            client: LiveFamiliarRosterClient(companion: companion),
            store: store
        )
    }

    func activate(_ profile: FamiliarProfileKey?) {
        invalidate()
        guard let profile else {
            activeProfile = nil
            selectedFamiliar = nil
            storeFailureReason = nil
            lastRefreshFailure = nil
            state = .idle
            return
        }

        let normalizedProfile = profile.normalized
        if activeProfile != normalizedProfile {
            lastRefreshFailure = nil
        }
        activeProfile = normalizedProfile
        publishCachedRoster(for: normalizedProfile)
        restoreSelection(
            for: normalizedProfile,
            clearPreviousFailure: true
        )
        restoreRefreshFailure(for: normalizedProfile)
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !Task.isCancelled else { return false }
        let snapshot = refreshSnapshotInFlight ?? refreshSnapshot()
        if refreshSnapshotInFlight != nil {
            restore(snapshot)
        }
        let refreshGeneration = beginRefresh(snapshot: snapshot)
        let gate = await client.gate()
        guard refreshGeneration == generation else { return false }
        guard !Task.isCancelled else {
            restore(snapshot)
            refreshSnapshotInFlight = nil
            return false
        }

        switch gate {
        case .notPaired:
            refreshSnapshotInFlight = nil
            publishRefreshFailure(
                "Pair with a daemon to load familiars."
            )
            return true
        case let .blocked(reason, hint):
            refreshSnapshotInFlight = nil
            publishRefreshFailure("\(reason) \(hint)")
            return true
        case let .ready(pairing):
            return await refresh(
                pairing: pairing,
                generation: refreshGeneration,
                snapshot: snapshot
            )
        }
    }

    func select(id: String?, for profile: FamiliarProfileKey) {
        activate(profile)
        guard let profile = activeProfile else { return }

        guard let id else {
            do {
                try store.save(nil, for: profile)
                selectedFamiliar = nil
                storeFailureReason = nil
                publishSuccessfulSelectionState(
                    for: profile,
                    fallback: hasValidatedRoster(for: profile) ? .loaded : .idle
                )
            } catch {
                publishStoreFailure(error)
            }
            return
        }

        guard let familiar = remoteFamiliar(for: id) else {
            state = .failed(
                reason: "The selected familiar is no longer available."
            )
            return
        }

        let selection = Self.identity(from: familiar)
        do {
            try store.save(selection, for: profile)
            selectedFamiliar = selection
            storeFailureReason = nil
            publishSuccessfulSelectionState(
                for: profile,
                fallback: .loaded
            )
        } catch {
            publishStoreFailure(error)
        }
    }

    func selection(for profile: FamiliarProfileKey) throws -> FamiliarIdentity? {
        try store.load(for: profile.normalized)
    }

    func remoteFamiliar(for id: String) -> RemoteFamiliar? {
        roster.first { Self.idsMatch($0.id, id) }
    }

    private func beginRefresh(snapshot: RefreshSnapshot) -> UInt64 {
        generation &+= 1
        refreshSnapshotInFlight = snapshot
        state = .loading
        return generation
    }

    private func invalidate() {
        generation &+= 1
        refreshSnapshotInFlight = nil
    }

    private func refresh(
        pairing: DaemonPairing,
        generation refreshGeneration: UInt64,
        snapshot: RefreshSnapshot
    ) async -> Bool {
        let endpoint = FamiliarProfileKey.companion(pairing: pairing)
        companionProfile = endpoint
        if case .companion = activeProfile {
            if activeProfile != endpoint {
                lastRefreshFailure = nil
            }
            activeProfile = endpoint
        }
        publishRosterForReadyEndpoint(endpoint)
        restoreActiveSelectionForRefresh()

        do {
            let fetched = try await client.familiars(pairing: pairing)
            guard refreshGeneration == generation else { return false }
            guard !Task.isCancelled else {
                restore(snapshot)
                refreshSnapshotInFlight = nil
                return false
            }
            refreshSnapshotInFlight = nil
            lastRefreshFailure = nil
            let sorted = Self.sorted(fetched)
            endpointRosterCache[endpoint] = sorted
            latestValidatedRoster = sorted
            roster = sorted
            reconcileActiveSelection(with: sorted)
            return true
        } catch {
            guard refreshGeneration == generation else { return false }
            guard !Task.isCancelled else {
                restore(snapshot)
                refreshSnapshotInFlight = nil
                return false
            }
            refreshSnapshotInFlight = nil
            publishRefreshFailure(error.localizedDescription)
            return true
        }
    }

    private func refreshSnapshot() -> RefreshSnapshot {
        RefreshSnapshot(
            roster: roster,
            state: state,
            selectedFamiliar: selectedFamiliar,
            activeProfile: activeProfile,
            companionProfile: companionProfile,
            endpointRosterCache: endpointRosterCache,
            latestValidatedRoster: latestValidatedRoster,
            storeFailureReason: storeFailureReason,
            lastRefreshFailure: lastRefreshFailure
        )
    }

    private func restore(_ snapshot: RefreshSnapshot) {
        roster = snapshot.roster
        state = snapshot.state
        selectedFamiliar = snapshot.selectedFamiliar
        activeProfile = snapshot.activeProfile
        companionProfile = snapshot.companionProfile
        endpointRosterCache = snapshot.endpointRosterCache
        latestValidatedRoster = snapshot.latestValidatedRoster
        storeFailureReason = snapshot.storeFailureReason
        lastRefreshFailure = snapshot.lastRefreshFailure
    }

    private func publishRosterForReadyEndpoint(
        _ endpoint: FamiliarProfileKey
    ) {
        guard let activeProfile else {
            roster = endpointRosterCache[endpoint] ?? []
            return
        }

        switch activeProfile {
        case .codex:
            roster = latestValidatedRoster ?? []
        case .companion:
            roster = endpointRosterCache[endpoint] ?? []
        }
    }

    private func publishCachedRoster(for profile: FamiliarProfileKey) {
        switch profile {
        case .codex:
            if let latestValidatedRoster {
                roster = latestValidatedRoster
                state = .loaded
            } else {
                roster = []
                state = .idle
            }
        case .companion:
            if let cached = endpointRosterCache[profile] {
                roster = cached
                state = .loaded
            } else {
                roster = []
                state = .idle
            }
        }
    }

    private func restoreActiveSelectionForRefresh() {
        guard let activeProfile, storeFailureReason == nil else { return }
        restoreSelection(
            for: activeProfile,
            clearPreviousFailure: false
        )
    }

    private func restoreSelection(
        for profile: FamiliarProfileKey,
        clearPreviousFailure: Bool
    ) {
        do {
            selectedFamiliar = try store.load(for: profile)
            if clearPreviousFailure {
                storeFailureReason = nil
            }
        } catch {
            selectedFamiliar = nil
            publishStoreFailure(error)
        }
    }

    private func reconcileActiveSelection(
        with fetched: [RemoteFamiliar]
    ) {
        guard let activeProfile else {
            selectedFamiliar = nil
            storeFailureReason = nil
            state = .loaded
            return
        }
        guard let storeFailureReason else {
            reconcileStoredSelection(
                for: activeProfile,
                with: fetched
            )
            return
        }
        state = .failed(reason: storeFailureReason)
    }

    private func reconcileStoredSelection(
        for profile: FamiliarProfileKey,
        with fetched: [RemoteFamiliar]
    ) {
        do {
            let stored = try store.load(for: profile)
            let refreshed = stored.flatMap { selection in
                fetched.first { Self.idsMatch($0.id, selection.id) }
            }.map(Self.identity(from:))
            try store.save(refreshed, for: profile)
            selectedFamiliar = refreshed
            state = .loaded
        } catch {
            publishStoreFailure(error)
        }
    }

    private func publishRefreshFailure(_ reason: String) {
        if let activeProfile {
            lastRefreshFailure = RefreshFailure(
                profile: activeProfile,
                reason: reason
            )
        }
        state = .failed(reason: storeFailureReason ?? reason)
    }

    private func restoreRefreshFailure(for profile: FamiliarProfileKey) {
        guard storeFailureReason == nil,
              let lastRefreshFailure,
              lastRefreshFailure.profile == profile else {
            return
        }
        state = .failed(reason: lastRefreshFailure.reason)
    }

    private func publishSuccessfulSelectionState(
        for profile: FamiliarProfileKey,
        fallback: State
    ) {
        guard let lastRefreshFailure,
              lastRefreshFailure.profile == profile else {
            state = fallback
            return
        }
        state = .failed(reason: lastRefreshFailure.reason)
    }

    private func publishStoreFailure(_ error: Error) {
        let reason = error.localizedDescription
        storeFailureReason = reason
        state = .failed(reason: reason)
    }

    private func hasValidatedRoster(
        for profile: FamiliarProfileKey
    ) -> Bool {
        switch profile {
        case .codex:
            return latestValidatedRoster != nil
        case .companion:
            return endpointRosterCache[profile] != nil
        }
    }

    private static func identity(
        from familiar: RemoteFamiliar
    ) -> FamiliarIdentity {
        FamiliarIdentity(
            id: familiar.id,
            displayName: familiar.displayName,
            emoji: familiar.emoji,
            role: familiar.role
        )
    }

    private static func idsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func sorted(
        _ familiars: [RemoteFamiliar]
    ) -> [RemoteFamiliar] {
        familiars.sorted { lhs, rhs in
            let names = lhs.displayName.caseInsensitiveCompare(rhs.displayName)
            if names != .orderedSame {
                return names == .orderedAscending
            }
            let ids = lhs.id.caseInsensitiveCompare(rhs.id)
            if ids != .orderedSame {
                return ids == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}
