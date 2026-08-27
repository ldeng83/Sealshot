import Foundation

/// Whether Sealshot locks itself every time it starts (the default) or opens
/// ready to use.
///
/// Stored as the OPT-OUT so `UserDefaults`' natural `false` for a missing key
/// means "lock at launch" — no `register(defaults:)` call, and no migration
/// that could flip existing installs to unlocked on upgrade.
///
/// Only meaningful while Enhanced security is on; the Settings row that writes
/// it is hidden otherwise, and `LaunchUnlockPolicy` re-checks anyway.
struct LaunchLockPreference {
    private static let key = "EncryptionSkipLaunchLock"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var locksAtLaunch: Bool {
        get { !defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(!newValue, forKey: Self.key) }
    }
}
