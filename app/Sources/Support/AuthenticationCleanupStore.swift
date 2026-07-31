import Foundation

protocol AuthenticationCleanupStore: AnyObject {
    var cleanupRequired: Bool { get set }
}

final class UserDefaultsAuthenticationCleanupStore: AuthenticationCleanupStore {
    private static let cleanupRequiredKey =
        "codex-authentication-cleanup-required"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var cleanupRequired: Bool {
        get {
            defaults.bool(forKey: Self.cleanupRequiredKey)
        }
        set {
            defaults.set(newValue, forKey: Self.cleanupRequiredKey)
        }
    }
}
