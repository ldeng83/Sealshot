import Foundation

/// Should the app unlock itself at launch instead of showing the lock screen?
///
/// Pure policy with injected inputs (same shape as `RelockController`'s
/// `shouldLockForIdle`) so the decision is testable without a keychain or a
/// live session. Fails closed: anything short of all three conditions leaves
/// the app locked, which is the behavior every build before this shipped with.
enum LaunchUnlockPolicy {
    /// - Parameters:
    ///   - encryptionEnabled: Enhanced security is on. Off means there is
    ///     nothing to unlock.
    ///   - identityAvailable: the identity key is reachable on this Mac. False
    ///     in the post-lockout / keychain-reset state, where a silent unlock
    ///     would fail anyway — staying locked lets the lock screen offer the
    ///     recovery path instead of dead-ending.
    ///   - locksAtLaunch: the user's `LaunchLockPreference` (default true).
    static func shouldUnlockAtLaunch(encryptionEnabled: Bool,
                                     identityAvailable: Bool,
                                     locksAtLaunch: Bool) -> Bool {
        encryptionEnabled && identityAvailable && !locksAtLaunch
    }
}
