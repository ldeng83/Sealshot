import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "recovery-entry")

/// Drives the "I'm on a new Mac, here's my recovery code" flow: read the
/// keystore.json that travels with the save folder, recover the identity,
/// persist it to the Keychain, re-provision the session, and unlock. Pure
/// logic (no UI) so it is unit-testable with an injected session + store.
@Observable
@MainActor
final class RecoveryEntryModel {
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let saveFolder: URL
    @ObservationIgnored private let session: EncryptionSession
    @ObservationIgnored private let identityStore: IdentityStore

    init(saveFolder: URL, session: EncryptionSession? = nil,
         identityStore: IdentityStore = KeychainIdentityStore()) {
        self.saveFolder = saveFolder
        self.session = session ?? EncryptionSession.shared
        self.identityStore = identityStore
    }

    /// Returns true on success (session is now unlocked). On failure sets
    /// `errorMessage` and leaves the session locked.
    @discardableResult
    func recover(code: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        guard let keystore = Keystore.read(fromFolder: saveFolder) else {
            errorMessage = "No recovery information was found next to your captures."
            return false
        }
        let identity: IdentityKey
        do {
            identity = try RecoveryKey.recover(escrow: keystore.escrow, code: code)
        } catch {
            errorMessage = "That recovery key didn't match. Check the code and try again."
            return false
        }
        do {
            // Restore under the generation the keystore escrowed, so the
            // keychain item, keyring, and existing capsules all agree.
            try identityStore.save(identity, for: keystore.generation)
            try session.provision(publicKey: identity.publicKey, generation: keystore.generation)
            // Adopt the just-recovered key directly — the recovery code already
            // proved ownership, so going through unlock()/load() would only
            // re-prompt Touch ID for a key the app is already holding (and the
            // keychain item may be unreachable, which is why we're here).
            session.adopt(identity)
            os_log("recovered identity from recovery code", log: log, type: .info)
            return true
        } catch {
            // Covers save / provision — keep the message generic so it never
            // wrongly implies which step failed.
            errorMessage = "Recovery failed: \(error.localizedDescription)"
            return false
        }
    }
}
