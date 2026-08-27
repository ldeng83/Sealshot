import Foundation

/// Verifies a recovery code against the local keystore to unlock the Privacy &
/// Security settings page — an alternative to device-owner (Touch ID / account
/// password) auth for an owner who can't use it (no biometrics enrolled, the
/// prompt unavailable) but kept the recovery code from when they turned on
/// encryption.
///
/// Unlike `RecoveryEntryModel` (the new-Mac flow) this only PROVES ownership:
/// it never adopts/provisions an identity, touches the Keychain, or changes the
/// session — this Mac already holds the identity, and the page gate just needs a
/// fresh owner check. A correct code is at least as strong a proof as the
/// device-owner prompt, so the caller may stamp `PrivacyAuthorization`.
enum RecoveryUnlock {
    /// Whether a recovery keystore exists to verify against — gates whether the
    /// "use recovery code" option is offered at all.
    static func isAvailable(saveFolder: URL) -> Bool {
        Keystore.read(fromFolder: saveFolder) != nil
    }

    /// True iff `code` matches the escrowed recovery key. The PBKDF2 derivation
    /// is CPU-heavy (600k iterations), so it runs off the main actor.
    static func verify(code: String, saveFolder: URL) async -> Bool {
        guard let escrow = Keystore.read(fromFolder: saveFolder)?.escrow else { return false }
        return await Task.detached(priority: .userInitiated) {
            (try? RecoveryKey.recover(escrow: escrow, code: code)) != nil
        }.value
    }
}
