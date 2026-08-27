import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "provisioner")

/// The engine behind the (Phase 2b) Settings toggle: turn encryption on/off
/// end to end. UI supplies confirmation + recovery-code ceremony; this does
/// the work. All-or-nothing where possible; migration is idempotent so a
/// crash mid-way is fixed by calling the same function again.
@MainActor
enum EncryptionProvisioner {
    enum Error: Swift.Error { case alreadyEnabled, notEnabled, lockedOut, notProvisioned }

    // MARK: - Public API (explicit parameters for testability)

    /// Generate identity + recovery code, persist everything, encrypt the
    /// existing library. Returns the recovery code — the UI must show it
    /// exactly once and require explicit confirmation.
    ///
    /// - Important: If `SealMigrator.encryptAll` throws
    ///   `SealMigrator.Error.migrationIncomplete`, the encryption flag is left
    ///   ON and keys are kept intact. Some packages were already locked; turning
    ///   off would orphan those captures. The caller should surface
    ///   "N captures couldn't be encrypted" to the user. Re-running `enable` is
    ///   invalid (`alreadyEnabled`); use `resumeMigration` instead to retry the
    ///   stragglers after the underlying cause is fixed.
    @discardableResult
    static func enable(
        saveFolder: URL,
        session: EncryptionSession,
        identityStore: IdentityStore,
        progress: (Int, Int) -> Void
    ) async throws -> String {
        guard !session.isEnabled else { throw Error.alreadyEnabled }

        let identity = IdentityKey.generate()
        let generation = KeyGeneration.make(publicKey: identity.publicKey)
        let code = RecoveryKey.generateCode()

        // Persist identity (under its generation) + keystore before flipping
        // anything.
        try identityStore.save(identity, for: generation)
        try Keystore.create(identity: identity, recoveryCode: code, generation: generation)
            .write(toFolder: saveFolder)

        // Provision the public key + generation (keyring) and unlock the session
        // so the migration pipeline can write locked packages immediately after.
        // Adopt the identity we just generated — `unlock()` would round-trip
        // through the keychain and auth-prompt the user mid-enable for no reason.
        try session.provision(publicKey: identity.publicKey, generation: generation)
        session.isEnabled = true
        session.adopt(identity)

        // Collections use the library-index content key but live outside the
        // disposable SQLite index. Convert their normal-mode JSON while the
        // freshly provisioned key is available; the helper removes plaintext
        // only after the sealed atomic write succeeds.
        if let collectionKey = try session.contentKey(for: .libraryIndex) {
            let directory = session.capsuleFolder.deletingLastPathComponent()
            try CollectionStore.migratePlaintextToSealed(in: directory, key: collectionKey)
        }
        NotificationCenter.default.post(name: .collectionsDidChange, object: nil)

        // Drop the plaintext search index NOW. It holds OCR text, titles and
        // tags from before encryption was on, and was otherwise removed only
        // by the first successful sealed write — so an interruption between
        // here and then left it readable on disk, and a later LOCKED launch
        // would open it and serve real search hits. The index is a disposable
        // cache; reconcile rebuilds it under the new key.
        LibraryIndexStore.purgePlaintextIndex()

        // Filename privacy default: unless the user explicitly chose, an
        // encrypted library names captures by timestamp only.
        FilenameIncludesTitlePreference.applyEncryptionPrivacyDefault(encryptionEnabled: true)

        os_log("encryption enabled — migrating library", log: log, type: .info)

        // Run the migration. If it throws migrationIncomplete, DO NOT flip the
        // flag off or remove keys: already-converted packages are locked and
        // need the identity. Rethrow so the UI can inform the user.
        // All other errors also rethrow (keys/flag stay for the same reason).
        try await SealMigrator.encryptAll(in: saveFolder, publicKey: identity.publicKey,
                                          generation: generation, progress: progress)

        // Encrypt existing recordings too (symmetric .recordings key, separate
        // pass; best-effort so a straggler never blocks enabling).
        if let recKey = try? session.contentKey(for: .recordings) {
            await RecordingsMigrator.encryptAll(in: saveFolder, key: recKey, progress: progress)
        }

        return code
    }

    /// What `disable` accomplished: how many packages it decrypted back to
    /// plaintext, and how many it couldn't (moved to `Locked-Unrecoverable/`).
    struct DisableSummary: Equatable { let decrypted: Int; let quarantined: Int }

    /// Turn encryption off — ALWAYS succeeds, regardless of key/identity state.
    /// Best-effort decrypts every package whose generation's key is reachable,
    /// quarantines the rest (never deletes, never blocks), then retires all keys
    /// and flips the flag off. With zero reachable identities, everything
    /// quarantines and the feature still turns off — the guaranteed escape from a
    /// diverged/locked-out state. Never throws.
    @discardableResult
    static func disable(
        saveFolder: URL,
        session: EncryptionSession,
        identityStore: IdentityStore,
        progress: (Int, Int) -> Void
    ) async -> DisableSummary {
        guard session.isEnabled else { return DisableSummary(decrypted: 0, quarantined: 0) }

        // Gather every reachable identity (may prompt once). A cancelled prompt
        // simply yields fewer keys → more packages quarantine; disable still runs.
        let keys = await session.reachableIdentities()

        // Recordings best-effort: adopt the active generation's identity (if we
        // have it but the session is locked) so the .recordings key is vendable.
        if !session.isUnlocked, let active = session.activeGeneration, let id = keys[active.id] {
            session.adopt(id)
        }
        if let recKey = try? session.contentKey(for: .recordings) {
            await RecordingsMigrator.decryptAll(in: saveFolder, key: recKey, progress: progress)
        }

        // Convert collection records before retiring the content-key capsule.
        // Disable remains best-effort, like recordings: if the key is genuinely
        // unreachable, preserve the sealed source instead of overwriting it.
        do {
            if let collectionKey = try session.contentKey(for: .libraryIndex) {
                let directory = session.capsuleFolder.deletingLastPathComponent()
                try CollectionStore.migrateSealedToPlaintext(in: directory, key: collectionKey)
            }
        } catch {
            os_log("collection decrypt migration failed: %{public}@",
                   log: log, type: .error, String(describing: error))
        }

        // Decrypt what we can; quarantine the rest.
        let outcome = await SealMigrator.decryptAll(
            in: saveFolder, keyFor: { keys[$0] }, progress: progress)
        var quarantined = 0
        for url in outcome.unrecoverable where (try? Quarantine.move(url, saveFolder: saveFolder)) != nil {
            quarantined += 1
        }

        // Retire everything (keychain items, keyring, capsules, public.key) and
        // flip the flag off. Best-effort keystore removal — a stray keystore with
        // no keyring/capsules is harmless and overwritten by the next enable.
        session.isEnabled = false
        session.retireKeyMaterial(identityStore: identityStore)
        try? FileManager.default.removeItem(at: saveFolder.appendingPathComponent(Keystore.filename))
        NotificationCenter.default.post(name: .collectionsDidChange, object: nil)

        os_log("encryption disabled — %d decrypted, %d quarantined",
               log: log, type: .info, outcome.decrypted, quarantined)
        return DisableSummary(decrypted: outcome.decrypted, quarantined: quarantined)
    }

    /// Re-run `encryptAll` for a partially-migrated library. Call this after
    /// `enable` threw `SealMigrator.Error.migrationIncomplete` and the
    /// underlying cause (e.g. a corrupted package) has been fixed.
    ///
    /// Precondition: the flag is already ON and the public key is available
    /// in the session (set by the original `enable` call).
    static func resumeMigration(
        saveFolder: URL,
        session: EncryptionSession,
        progress: (Int, Int) -> Void
    ) async throws {
        guard session.isEnabled else { throw Error.notEnabled }
        guard let publicKey = session.publicKey,
              let generation = session.activeGeneration else { throw Error.notProvisioned }

        os_log("resuming migration — re-encrypting stragglers", log: log, type: .info)
        try await SealMigrator.encryptAll(in: saveFolder, publicKey: publicKey,
                                          generation: generation, progress: progress)
        if let recKey = try? session.contentKey(for: .recordings) {
            await RecordingsMigrator.encryptAll(in: saveFolder, key: recKey, progress: progress)
        }
    }

    // MARK: - Recovery code (view / regenerate)

    /// Reveal the existing recovery code. Requires an unlockable session (the
    /// identity unwraps the sealed code). Nil if locked-out or no keystore.
    static func viewRecoveryCode(saveFolder: URL, session: EncryptionSession) async -> String? {
        guard (try? await session.unlock()) == true,
              let identity = session.unlockedIdentityForDrain(),
              let keystore = Keystore.read(fromFolder: saveFolder)
        else { return nil }
        return keystore.recoveryCode(unwrappingWith: identity)
    }

    /// Rotate the recovery code: generate a new one, re-escrow the SAME identity
    /// under it, and re-seal it — overwriting the keystore. The old code stops
    /// working. Returns the new code to display, or nil if locked-out.
    static func regenerateRecoveryCode(saveFolder: URL, session: EncryptionSession) async -> String? {
        guard (try? await session.unlock()) == true,
              let identity = session.unlockedIdentityForDrain(),
              let generation = session.activeGeneration,
              let keystore = try? Keystore.create(
                identity: identity, recoveryCode: RecoveryKey.generateCode(), generation: generation),
              (try? keystore.write(toFolder: saveFolder)) != nil
        else { return nil }
        return keystore.recoveryCode(unwrappingWith: identity)
    }

    // MARK: - Key rotation / revocation

    struct RotateSummary: Equatable {
        let newRecoveryCode: String
        let rekeyedPackages: Int
        let failedPackages: Int
    }

    /// Rotate to a fresh identity + recovery code, re-keying all data FORWARD
    /// (re-wrapping content keys — data bytes untouched) and retiring the old
    /// generation. Invalidates the old identity and old recovery code. Returns the
    /// new recovery code, or nil if the current key can't be unlocked (you can
    /// only re-wrap what you can currently unwrap — recover first if locked out).
    static func rotateKey(saveFolder: URL, session: EncryptionSession,
                          identityStore: IdentityStore) async -> RotateSummary? {
        guard session.isEnabled,
              (try? await session.unlock()) == true,
              let oldIdentity = session.unlockedIdentityForDrain(),
              let oldGeneration = session.activeGeneration
        else { return nil }

        let newIdentity = IdentityKey.generate()
        let newGeneration = KeyGeneration.make(publicKey: newIdentity.publicKey)
        let newCode = RecoveryKey.generateCode()

        // Re-wrap content keys forward (data NOT re-encrypted). Store capsules are
        // transactional; package lids and pending entries are best-effort.
        do {
            try session.rekeyStoreCapsules(
                to: newIdentity.publicKey, generation: newGeneration, using: oldIdentity)
        } catch {
            os_log("rotateKey: store-capsule re-key failed — %{public}@",
                   log: log, type: .error, "\(error)")
            return nil
        }
        let pkg = await SealMigrator.rekeyAll(
            in: saveFolder, old: oldIdentity, new: newIdentity.publicKey, generation: newGeneration)
        PendingIndexQueue(folder: PendingIndexQueue.defaultFolder)
            .rekey(old: oldIdentity, new: newIdentity.publicKey, generation: newGeneration)

        // Persist the new generation. Keystore.create overwrites the keystore, so
        // the old escrow + old sealed code are gone → the old recovery code is dead.
        try? identityStore.save(newIdentity, for: newGeneration)
        try? Keystore.create(identity: newIdentity, recoveryCode: newCode, generation: newGeneration)
            .write(toFolder: saveFolder)
        try? session.provision(publicKey: newIdentity.publicKey, generation: newGeneration)
        session.adopt(newIdentity)

        // Retire + delete the old generation (its keychain item is removed).
        session.retireGeneration(oldGeneration, identityStore: identityStore, at: Date())

        os_log("rotateKey: rotated to a new generation — %d packages re-keyed, %d failed",
               log: log, type: .info, pkg.rekeyed, pkg.failed.count)
        return RotateSummary(newRecoveryCode: newCode,
                             rekeyedPackages: pkg.rekeyed, failedPackages: pkg.failed.count)
    }

    // MARK: - Convenience overloads using shared defaults

    /// Convenience: uses `EncryptionSession.shared` and `KeychainIdentityStore()`.
    @discardableResult
    static func enable(saveFolder: URL, progress: (Int, Int) -> Void) async throws -> String {
        try await enable(saveFolder: saveFolder, session: .shared,
                         identityStore: KeychainIdentityStore(), progress: progress)
    }

    /// Convenience: uses `EncryptionSession.shared` and `KeychainIdentityStore()`.
    @discardableResult
    static func disable(saveFolder: URL, progress: (Int, Int) -> Void) async -> DisableSummary {
        await disable(saveFolder: saveFolder, session: .shared,
                      identityStore: KeychainIdentityStore(), progress: progress)
    }

    /// Convenience: uses `EncryptionSession.shared`.
    static func resumeMigration(saveFolder: URL, progress: (Int, Int) -> Void) async throws {
        try await resumeMigration(saveFolder: saveFolder, session: .shared, progress: progress)
    }
}
