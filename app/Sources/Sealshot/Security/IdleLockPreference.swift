import Foundation

/// Minutes of inactivity before auto-lock. 0 == disabled (default).
struct IdleLockPreference {
    private static let key = "EncryptionIdleLockMinutes"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var minutes: Int {
        get { defaults.integer(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
