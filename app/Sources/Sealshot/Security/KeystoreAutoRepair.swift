import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "encryption")

/// Self-heal for an accidentally deleted `keystore.json`.
///
/// The keystore is the recovery escrow — losing it silently costs the user
/// both the recovery-code path and the backups-carry-keys property, and the
/// consistency check can't see that while the Keychain identity is healthy.
/// So: whenever the session unlocks (the identity is in memory — no extra
/// auth prompt) and the file is missing, re-escrow the SAME identity under a
/// FRESH recovery code and rewrite the file. The old code can't be restored —
/// it only existed sealed inside the deleted file — so the caller must show
/// the returned new code to the user.
enum KeystoreAutoRepair {

    /// Session convenience: uses the in-memory identity + active generation.
    @MainActor
    static func repairIfNeeded(session: EncryptionSession, saveFolder: URL) -> String? {
        repair(identity: session.unlockedIdentityForDrain(),
               generation: session.activeGeneration,
               enabled: session.isEnabled,
               saveFolder: saveFolder)
    }

    /// Core (parameter-injected for tests). Returns the NEW recovery code when
    /// a keystore was actually recreated; nil when there is nothing to do
    /// (disabled, locked, or the file is present) or the write failed.
    static func repair(identity: IdentityKey?, generation: KeyGeneration?,
                       enabled: Bool, saveFolder: URL) -> String? {
        guard enabled, let identity, let generation else { return nil }
        let path = saveFolder.appendingPathComponent(Keystore.filename).path
        guard !FileManager.default.fileExists(atPath: path) else { return nil }

        let code = RecoveryKey.generateCode()
        guard let keystore = try? Keystore.create(
                identity: identity, recoveryCode: code, generation: generation),
              (try? keystore.write(toFolder: saveFolder)) != nil else {
            os_log("keystore auto-repair: rewrite failed", log: log, type: .error)
            return nil
        }
        os_log("keystore auto-repair: recreated missing keystore.json (new recovery code issued)",
               log: log, type: .default)
        return code
    }
}
