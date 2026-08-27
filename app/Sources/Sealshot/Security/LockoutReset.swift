import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "lockout-reset")

/// The last-resort "start over" action for a genuinely locked-out library —
/// no reachable identity AND no working recovery code. Rather than leave the
/// user permanently stuck, this archives every package this Mac can no
/// longer read, PLUS every piece of key material that could ever have
/// unlocked them, into `Locked-Unrecoverable/` — nothing is deleted, nothing
/// re-encrypted, nothing decrypted — and then turns encryption off so the
/// app is immediately usable again. Plaintext packages are left untouched.
///
/// Ordering is the whole point: the archive (packages, then keystore/keyring/
/// capsules) MUST complete before `EncryptionSession.retireKeyMaterial`
/// deletes the originals, or the "restore later" path this exists to
/// preserve would be destroyed instead. A package that fails to move is
/// left in place and reported in `Summary.failed` — everything else still
/// proceeds; but a failure archiving the keystore/keyring/capsules throws
/// and stops the whole reset, because that step has no acceptable partial
/// outcome (see the ordering note above).
///
/// Repeat resets accumulate, they never clobber: a user can go through
/// reset → re-enable encryption → get locked out again → reset any number
/// of times, and every cycle's restore seeds survive under
/// `Quarantine.uniqueDestination`'s `-1`/`-2`/… suffixing (`keystore.json`,
/// `keystore-1.json`, …) — same idiom the packages above already get.
/// Nothing this type archives is ever deleted or overwritten, full stop.
///
/// Design note for the future restore engine: it should try EACH archived
/// `keystore*.json` against the user's typed recovery code in turn.
/// `RecoveryKey.recover` fails cleanly on an escrow that doesn't match, so
/// the recovery code itself picks out the right seed — there's no need to
/// know in advance which cycle a given locked package came from, which is
/// exactly why uniquely-suffixed seeds (rather than a single overwritten
/// one) are fully restorable.
@MainActor
enum LockoutReset {
    struct Summary {
        /// Locked packages successfully archived under `Locked-Unrecoverable/`.
        let archivedPackages: Int
        /// Locked packages that could not be moved — left in place.
        let failed: [URL]
        /// The `Locked-Unrecoverable` folder everything was archived into.
        let archiveFolder: URL
    }

    /// Subfolders of `saveFolder` that may hold `.seal` package directories;
    /// `""` means `saveFolder` itself.
    private static let packageFolderNames = ["", "Deleted", "Recordings"]

    static func perform(saveFolder: URL, session: EncryptionSession,
                        identityStore: IdentityStore) throws -> Summary {
        let fm = FileManager.default
        let archiveFolder = saveFolder.appendingPathComponent(Quarantine.folderName, isDirectory: true)
        try fm.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        // `Locked-Unrecoverable/` can also hold disable-time quarantine
        // content (see `Quarantine`'s own README.txt) that has no recovery
        // seed and is never restorable — a customer who finds this folder
        // shouldn't assume everything in it comes back with a code. Write a
        // distinct, reset-specific note alongside (never touching or
        // overwriting Quarantine's own file); always rewritten so repeat
        // resets never leave it stale.
        writeResetReadme(in: archiveFolder)

        // 1. Archive every locked package across all three package folders.
        // Plaintext packages are never touched. A package that fails to move
        // is left in place and reported — everything else still proceeds.
        var archivedPackages = 0
        var failed: [URL] = []
        for name in packageFolderNames {
            let dir = name.isEmpty ? saveFolder : saveFolder.appendingPathComponent(name, isDirectory: true)
            let packages = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "seal" }
            for pkg in packages where SealPackageCrypter.isLocked(pkg) {
                do {
                    _ = try Quarantine.move(pkg, saveFolder: saveFolder)
                    archivedPackages += 1
                } catch {
                    os_log("LockoutReset: could not archive %{public}@: %{public}@",
                           log: log, type: .error, pkg.lastPathComponent, String(describing: error))
                    failed.append(pkg)
                }
            }
        }

        // 2. Archive the restore seeds BEFORE anything below deletes them.
        // keystore.json lives in the save-folder root; keyring.json + the
        // per-store capsules + the legacy public.key live in the capsule
        // folder (see Keyring.swift / EncryptionSession.retireKeyMaterial).
        // These throw on failure — swallowing an error here would mean
        // proceeding to retire the originals with no surviving copy.
        let keystoreSrc = saveFolder.appendingPathComponent(Keystore.filename)
        if fm.fileExists(atPath: keystoreSrc.path) {
            try archive(keystoreSrc, movingInto: archiveFolder, as: Keystore.filename)
        }
        // keyring.json is COPIED, not moved: retireKeyMaterial() below
        // re-reads it from the capsule folder to enumerate every generation
        // and delete each one's OWN keychain item (KeychainIdentityStore
        // scopes accounts by generation ID — see IdentityStore.swift). Moving
        // it out first would make that read return nil, silently skipping
        // every per-generation delete. retireKeyMaterial's own cleanup (its
        // `names` delete-list includes Keyring.filename) removes the
        // original from the capsule folder once it's done with it.
        let keyringSrc = session.capsuleFolder.appendingPathComponent(Keyring.filename)
        if fm.fileExists(atPath: keyringSrc.path) {
            try archive(keyringSrc, copyingInto: archiveFolder, as: Keyring.filename)
        }
        // Whatever else remains in the capsule folder (per-store .capsule
        // files, the legacy public.key) is also copied — not moved — into
        // keys/, for the same reason: retireKeyMaterial still needs to find
        // and delete the originals. keyring.json is excluded here since it's
        // already archived above, at the archive root rather than keys/.
        let keysArchiveFolder = archiveFolder.appendingPathComponent("keys", isDirectory: true)
        try fm.createDirectory(at: keysArchiveFolder, withIntermediateDirectories: true)
        if let remaining = try? fm.contentsOfDirectory(
            at: session.capsuleFolder, includingPropertiesForKeys: nil) {
            for item in remaining where item.lastPathComponent != Keyring.filename {
                try archive(item, copyingInto: keysArchiveFolder, as: item.lastPathComponent)
            }
        }

        // 3. Only now disable + retire — the archive above already holds
        // everything a later restore would need. Zero keychain reads: this
        // deletes key material, it never loads any.
        session.isEnabled = false
        session.lock()
        session.retireKeyMaterial(identityStore: identityStore)
        // retireKeyMaterial doesn't itself notify; post the same notification
        // lock()/unlock()/adopt() use, so overlays/library refresh against the
        // final, fully-retired state (activeGeneration/publicKey now nil).
        // Intentional SECOND post in this call: lock() above already posted
        // the mid-transition (locked-but-not-yet-retired) state; this one
        // posts the settled post-retirement state so listeners land on it.
        NotificationCenter.default.post(name: .encryptionLockStateDidChange, object: session)

        return Summary(archivedPackages: archivedPackages, failed: failed, archiveFolder: archiveFolder)
    }

    /// Archives `src` under `folder` as `name`, never clobbering an existing
    /// file there — collision-safe via `Quarantine.uniqueDestination`, same
    /// as locked packages. Nothing already in the archive is ever removed.
    private static func archive(_ src: URL, movingInto folder: URL, as name: String) throws {
        let dest = Quarantine.uniqueDestination(for: name, in: folder)
        try FileManager.default.moveItem(at: src, to: dest)
    }

    private static func archive(_ src: URL, copyingInto folder: URL, as name: String) throws {
        let dest = Quarantine.uniqueDestination(for: name, in: folder)
        try FileManager.default.copyItem(at: src, to: dest)
    }

    /// A reset-specific note next to (never replacing) `Quarantine`'s own
    /// `README.txt` — the two files cover DIFFERENT content that can coexist
    /// in the same folder: reset-archived items (restorable in-app with the
    /// recovery code from before that reset) versus disable-time quarantine
    /// content (no seed archived — see `EncryptionProvisioner.disable` — and
    /// never restorable). Purely informational; nothing here is read back by
    /// the app, so always (re)writing it on every reset is harmless and keeps
    /// it from going stale across repeat resets.
    private static func writeResetReadme(in folder: URL) {
        let text = """
        ITEMS FROM A SEALSHOT LOCKOUT RESET

        Some of what's in this folder was moved here by Sealshot's guided
        lockout reset ("I can't unlock…" ▸ Reset). Those items ARE
        restorable — from inside Sealshot, using Settings → Privacy &
        Security → Locked Archive (or the Library's Locked Archive banner)
        → Restore…, with the recovery code from before that reset.

        This folder can also hold OTHER content that is NOT restorable:
        captures Sealshot could not decrypt when Enhanced security was
        turned off (see README.txt in this same folder, if present). That
        content has no recovery seed and cannot be brought back through
        Restore… — nothing has been deleted either way.
        """
        try? Data(text.utf8).write(
            to: folder.appendingPathComponent("README-reset.txt"), options: .atomic)
    }
}
