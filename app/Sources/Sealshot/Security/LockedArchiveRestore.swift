import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "locked-archive-restore")

/// Reverses a `LockoutReset` for one encryption cycle: the user types the
/// recovery code they've found again, and everything that code can actually
/// serve comes back — the packages, the keystore, the keyring records, the
/// store capsules, and a re-enabled, unlocked session.
///
/// The archive may hold seeds from SEVERAL reset cycles (`keystore.json`,
/// `keystore-1.json`, … — see `LockoutReset`'s accumulate guarantee), and the
/// suffix numbers do NOT pair across file types: `keystore-1.json` and
/// `keyring-1.json` can be from different cycles. So nothing here trusts
/// filenames to pair anything. The typed code is the selector: it is tried
/// against EACH archived keystore's escrow — `RecoveryKey.recover` fails
/// cleanly (authenticated AES-GCM) on a non-matching escrow, so a success
/// identifies exactly one cycle with no false positives. Keyrings are matched
/// by CONTENT (the ledger that carries the recovered generation), store
/// capsules by their capsule's `generationID`, and packages by their
/// `lock.json` capsule's `generationID` — verified with an actual unwrap, so
/// a package only leaves the archive when the recovered key demonstrably
/// opens it. Packages from OTHER cycles stay archived and are reported as
/// `stillArchived`, so the UI can say "restore them with their own code".
///
/// Failure discipline mirrors `LockoutReset`: nothing in the archive is ever
/// deleted or clobbered on a failure path. Until the code matches, the engine
/// is strictly read-only. After the match, every file restore is best-effort
/// and collision-safe (`Quarantine.uniqueDestination`); a package that can't
/// be moved back stays in the archive, ciphertext intact, and is reported in
/// `failed`.
@MainActor
enum LockedArchiveRestore {
    struct Summary: Equatable {
        /// Packages moved back into the save-folder root, openable again.
        let restoredPackages: Int
        /// Locked packages left in the archive because the recovered key
        /// cannot open them — they belong to a different reset cycle (or
        /// their header is unreadable) and need their own code.
        let stillArchived: Int
        /// Packages the recovered key CAN open but that could not be moved
        /// back — left in the archive, nothing deleted.
        let failed: [URL]
        /// Store slots (named by `EncryptionSession.Store.rawValue`, e.g.
        /// "history") whose capsule could not be restored or displaced —
        /// that store's data encrypted before the reset may be unreadable
        /// until this is resolved. Never aborts the restore: packages and
        /// other stores are independent of any one capsule's fate.
        let capsuleFailures: [String]
        /// True when the matched keystore could not be moved back to the
        /// canonical `keystore.json` (step 4). The recovered identity is
        /// still adopted and packages still restore — this only means
        /// `keystore.json` may not (yet) escrow the active generation, which
        /// View Recovery Code and the consistency check read.
        let keystoreMoveFailed: Bool
        /// True when this restore displaced a LIVE (never-reset) cycle's
        /// canonical keystore and/or an occupied store capsule to make room
        /// for the recovered cycle — see the displacement branches in steps
        /// 4 and 6. That live cycle's own keystore/capsule is still intact
        /// (moved into the archive, never deleted or overwritten), but its
        /// data is not reachable again until IT is restored with its own
        /// recovery code. Only true when a displacement actually happened,
        /// never on a plain single-cycle round-trip.
        let displacedLiveCycle: Bool
    }

    enum Error: Swift.Error, Equatable {
        /// The archive is missing or holds no decodable `keystore*.json` —
        /// there is nothing a recovery code could ever match.
        case noArchivedKeystore
        /// The code matched none of the archived keystore escrows.
        case codeDoesNotMatch
    }

    static func archiveFolder(saveFolder: URL) -> URL {
        saveFolder.appendingPathComponent(Quarantine.folderName, isDirectory: true)
    }

    /// Cheap stat-level snapshot for the Settings row: how many packages sit
    /// in the archive, and whether at least one keystore seed exists for a
    /// code to match. No decryption, no JSON parsing beyond none.
    struct Status: Equatable {
        let archivedPackages: Int
        let hasKeystore: Bool
    }

    static func status(saveFolder: URL) -> Status {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: archiveFolder(saveFolder: saveFolder), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return Status(
            archivedPackages: contents.filter { $0.pathExtension.lowercased() == "seal" }.count,
            hasKeystore: contents.contains { isKeystoreCandidate($0) })
    }

    // MARK: - Restore

    static func restore(code: String, saveFolder: URL, session: EncryptionSession,
                        identityStore: IdentityStore) async throws -> Summary {
        let fm = FileManager.default
        let archive = archiveFolder(saveFolder: saveFolder)

        // 1. Enumerate keystore seeds. Everything up to a successful code
        // match is strictly read-only — a wrong code leaves the archive (and
        // the session) byte-for-byte untouched.
        let contents = (try? fm.contentsOfDirectory(
            at: archive, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let keystoreCandidates = contents.filter { isKeystoreCandidate($0) }
            .compactMap { url in readKeystore(at: url).map { (url: url, keystore: $0) } }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        guard !keystoreCandidates.isEmpty else { throw Error.noArchivedKeystore }

        // 2. The code selects its cycle: try it against each escrow in turn.
        // Each attempt is a 600k-iteration PBKDF2 derivation (RecoveryKey.
        // recover), and an archive can hold several cycles' seeds — running
        // that on @MainActor would block the UI for the whole scan. Hop the
        // CANDIDATE-MATCHING loop off-main (mirrors RecoveryUnlock.verify's
        // Task.detached idiom); the cheap file reads above and every
        // filesystem mutation below stay on @MainActor as before.
        let matchTask = Task.detached(priority: .userInitiated) { () -> (url: URL, keystore: Keystore, identity: IdentityKey)? in
            for candidate in keystoreCandidates {
                if let identity = try? RecoveryKey.recover(escrow: candidate.keystore.escrow, code: code) {
                    return (candidate.url, candidate.keystore, identity)
                }
            }
            return nil
        }
        guard let match = await matchTask.value else { throw Error.codeDoesNotMatch }
        let generation = match.keystore.generation
        os_log("restore: code matched %{public}@ (generation %{public}@)",
               log: log, type: .info, match.url.lastPathComponent, generation.id.uuidString)

        // 3. Adopt the recovered identity — same order as the proven recovery
        // flow (RecoveryEntryModel): persist under its generation, record it
        // in the keyring as the active generation (provision appends, never
        // clobbers — a live cycle's records survive), unlock by adoption.
        try identityStore.save(match.identity, for: generation)
        try session.provision(publicKey: match.identity.publicKey, generation: generation)
        session.adopt(match.identity)

        // 4. The matched keystore is live again: MOVE it back to the
        // save-folder root as the canonical keystore.json — that file must
        // always escrow the ACTIVE generation (View Recovery Code and the
        // consistency check read only it). A keystore.json already at the
        // root (another cycle's — e.g. a fully live, never-reset cycle) is
        // displaced INTO THE ARCHIVE first, never the save-folder root:
        // `restore()`'s candidate scan only ever reads `archive`, so a
        // displacement into the save-folder root would silently strand that
        // cycle — permanently unrestorable through the UI even though
        // nothing was deleted. Landing it in the archive instead makes it
        // immediately a restorable candidate again, same as any other
        // archived seed. Never deleted, never overwritten either way.
        // Best-effort: on failure the seed simply stays in the archive for a
        // retry; recorded in the Summary rather than swallowed.
        var keystoreMoveFailed = false
        var displacedLiveKeystore = false
        do {
            let canonical = saveFolder.appendingPathComponent(Keystore.filename)
            if fm.fileExists(atPath: canonical.path) {
                try fm.moveItem(at: canonical,
                                to: Quarantine.uniqueDestination(for: Keystore.filename,
                                                                 in: archive))
                displacedLiveKeystore = true
            }
            try fm.moveItem(at: match.url, to: canonical)
        } catch {
            keystoreMoveFailed = true
            os_log("restore: could not move keystore back: %{public}@",
                   log: log, type: .error, String(describing: error))
        }

        // 5. Fold the matched cycle's keyring ledger into the live keyring.
        // Candidates are identified by CONTENT — the archived keyring whose
        // records include the recovered generation — never by suffix number.
        // Records merge append-only into the live keyring (which `provision`
        // just wrote/extended); a fully-merged archive copy is then removed —
        // every record it held now lives in the working keyring.
        mergeArchivedKeyrings(in: contents, generation: generation, session: session)

        // 6. Store capsules: for each store slot the session expects, restore
        // the archived capsule stamped with the recovered generation. An
        // occupied slot (another cycle's capsule — its data is what the
        // current store files are actually encrypted under) is never
        // clobbered: it is DISPLACED into the archive first, content-stamped
        // with its own generation, so it stays a restorable seed for ITS
        // cycle — exactly the same never-clobber, content-addressed pattern
        // step 4 now uses for the canonical keystore — and only then is the
        // recovered generation's own capsule moved into the vacated slot.
        // Failures (per store) are collected rather than swallowed; a
        // capsule that can't be restored never aborts the rest of the
        // restore, since packages and other stores don't depend on it.
        let (capsuleFailures, displacedLiveCapsule) = restoreStoreCapsules(
            archive: archive, generation: generation, session: session)
        // The capsule files on disk may have just changed for stores this
        // session already cached a key for (e.g. from writes made earlier in
        // the same run, before the user ever found their old code) — drop
        // the cache so `contentKey(for:)` re-reads instead of silently
        // keeping a now-stale key.
        session.invalidateContentKeyCache()

        // 7. The feature is on again — the recovered code stays valid, no
        // new ceremony.
        session.isEnabled = true

        // 8. Move back ONLY the packages that belong to the RECOVERED
        // cycle: their `lock.json` capsule's `generationID` must equal this
        // restore's generation, AND the recovered identity must actually
        // unwrap the CEK. This is deliberately narrower than "any reachable
        // identity can open it" — in the restore-while-live edge (see
        // `testDisplacedLiveKeystoreStaysRestorableFromArchive`) another
        // cycle's identity can be reachable via the keyring's stored
        // keychain item even while THIS restore is running, but runtime only
        // ever adopts a single identity at a time. Returning that other
        // cycle's package to the library now would silently strand it —
        // unopenable until its own restore runs — which is worse than
        // leaving it archived behind the archive's explanatory banner.
        // Packages from other cycles are counted in `stillArchived` even
        // though some other live identity could open them.
        var restored = 0
        var stillArchived = 0
        var failed: [URL] = []
        let packages = ((try? fm.contentsOfDirectory(
            at: archive, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "seal" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for pkg in packages {
            guard canOpen(pkg, generation: generation, identity: match.identity) else {
                stillArchived += 1
                continue
            }
            do {
                let dest = Quarantine.uniqueDestination(for: pkg.lastPathComponent, in: saveFolder)
                try fm.moveItem(at: pkg, to: dest)
                restored += 1
            } catch {
                os_log("restore: could not move %{public}@ back: %{public}@",
                       log: log, type: .error, pkg.lastPathComponent, String(describing: error))
                failed.append(pkg)
            }
        }

        // Settle listeners on the final state (enabled + unlocked) — adopt()
        // posted mid-transition, before isEnabled flipped, same double-post
        // rationale as LockoutReset.
        NotificationCenter.default.post(name: .encryptionLockStateDidChange, object: session)

        let displacedLiveCycle = displacedLiveKeystore || displacedLiveCapsule
        os_log("restore: %d restored, %d still archived, %d failed, %d capsule failures, keystore move failed: %{public}@, displaced live cycle: %{public}@",
               log: log, type: .info, restored, stillArchived, failed.count,
               capsuleFailures.count, String(keystoreMoveFailed), String(displacedLiveCycle))
        return Summary(restoredPackages: restored, stillArchived: stillArchived, failed: failed,
                       capsuleFailures: capsuleFailures, keystoreMoveFailed: keystoreMoveFailed,
                       displacedLiveCycle: displacedLiveCycle)
    }

    // MARK: - Keystore seeds

    private static func isKeystoreCandidate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("keystore") && url.pathExtension == "json"
    }

    /// `Keystore.read(fromFolder:)` hardcodes `keystore.json`; archived seeds
    /// carry unique suffixes, so decode from the explicit URL with the same
    /// version guard.
    private static func readKeystore(at url: URL) -> Keystore? {
        guard let data = try? Data(contentsOf: url),
              let keystore = try? JSONDecoder().decode(Keystore.self, from: data),
              keystore.version == Keystore.currentVersion
        else { return nil }
        return keystore
    }

    // MARK: - Keyring merge

    private static func mergeArchivedKeyrings(in archiveContents: [URL],
                                              generation: KeyGeneration,
                                              session: EncryptionSession) {
        let candidates = archiveContents.filter {
            $0.lastPathComponent.hasPrefix("keyring") && $0.pathExtension == "json"
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let archived = try? JSONDecoder().decode(Keyring.self, from: data),
                  archived.version == Keyring.currentVersion,
                  archived.generations.contains(where: { $0.generation.id == generation.id }),
                  var live = Keyring.read(fromFolder: session.capsuleFolder)
            else { continue }
            for record in archived.generations
            where live.record(for: record.generation.id) == nil {
                live = live.appending(record, active: false)
            }
            do {
                try live.write(toFolder: session.capsuleFolder)
                // Fully merged — the archive copy holds no record the live
                // ledger doesn't. Removing it is what empties the archive of
                // this cycle's seeds; a failed remove just leaves a stale
                // (harmless) copy behind.
                try? FileManager.default.removeItem(at: url)
            } catch {
                os_log("restore: keyring merge write failed: %{public}@",
                       log: log, type: .error, String(describing: error))
            }
        }
    }

    // MARK: - Store capsules

    /// Returns the `Store.rawValue` names whose capsule could not be
    /// restored or displaced — surfaced in `Summary.capsuleFailures` rather
    /// than swallowed — plus whether any OTHER (live) cycle's occupied
    /// capsule had to be displaced to make room, surfaced in
    /// `Summary.displacedLiveCycle`. Never throws: a failure on one store
    /// never blocks any other store or the rest of the restore.
    private static func restoreStoreCapsules(archive: URL, generation: KeyGeneration,
                                             session: EncryptionSession) -> (failures: [String], displacedLiveCycle: Bool) {
        let fm = FileManager.default
        let keysFolder = archive.appendingPathComponent("keys", isDirectory: true)
        var failures: [String] = []
        var displacedLiveCycle = false

        for store in EncryptionSession.Store.allCases {
            let liveURL = session.capsuleFolder.appendingPathComponent("\(store.rawValue).capsule")

            if fm.fileExists(atPath: liveURL.path) {
                // Occupied: it belongs to some other cycle's stores (its
                // data is what the current store files are actually
                // encrypted under). Read it first — if it already carries
                // the recovered generation's stamp there's nothing to do.
                guard let data = try? Data(contentsOf: liveURL),
                      let occupant = try? JSONDecoder().decode(KeyCapsule.self, from: data)
                else {
                    os_log("restore: could not read occupied %{public}@ capsule",
                           log: log, type: .error, store.rawValue)
                    failures.append(store.rawValue)
                    continue
                }
                if occupant.generationID == generation.id { continue }

                // Never clobbered, never re-wrapped in place (that would
                // discard the occupant's own key material under a foreign
                // generation stamp — indistinguishable from data loss the
                // next time ITS cycle needs restoring). Instead DISPLACE it
                // into the archive, content-stamped with its own
                // generation, so it stays a legitimate restorable seed for
                // its own cycle — same never-clobber idiom as the canonical
                // keystore in step 4.
                do {
                    try fm.createDirectory(at: keysFolder, withIntermediateDirectories: true)
                    let displaced = Quarantine.uniqueDestination(
                        for: "\(store.rawValue).capsule", in: keysFolder)
                    try fm.moveItem(at: liveURL, to: displaced)
                    displacedLiveCycle = true
                } catch {
                    os_log("restore: could not displace occupied %{public}@ capsule: %{public}@",
                           log: log, type: .error, store.rawValue, String(describing: error))
                    failures.append(store.rawValue)
                    continue
                }
            }

            // Empty slot (or just emptied above): bring back this cycle's
            // own capsule, matched by the generation stamped INSIDE it —
            // never by suffix number. Re-list the archive each time through
            // the loop since the occupied-slot branch above may just have
            // added to it.
            let archivedCapsules = (try? fm.contentsOfDirectory(
                at: keysFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            guard let candidate = archivedCapsules
                .filter({ $0.lastPathComponent.hasPrefix(store.rawValue) && $0.pathExtension == "capsule" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .first(where: {
                    guard let data = try? Data(contentsOf: $0),
                          let capsule = try? JSONDecoder().decode(KeyCapsule.self, from: data)
                    else { return false }
                    return capsule.generationID == generation.id
                })
            // This cycle never touched this store — nothing archived for it,
            // nothing to restore, not a failure.
            else { continue }

            do {
                try fm.createDirectory(at: session.capsuleFolder, withIntermediateDirectories: true)
                try fm.moveItem(at: candidate, to: liveURL)
            } catch {
                os_log("restore: could not restore %{public}@: %{public}@",
                       log: log, type: .error, candidate.lastPathComponent,
                       String(describing: error))
                failures.append(store.rawValue)
            }
        }
        return (failures, displacedLiveCycle)
    }

    // MARK: - Package reachability

    /// Whether the RECOVERED cycle's identity demonstrably opens `pkg`: the
    /// lock header must decode, its capsule's `generationID` must be this
    /// restore's generation (never some other reachable cycle's), and that
    /// generation's identity must actually unwrap the CEK.
    private static func canOpen(_ pkg: URL, generation: KeyGeneration, identity: IdentityKey) -> Bool {
        guard let data = try? Data(contentsOf: pkg.appendingPathComponent(LockHeader.filename)),
              let header = try? JSONDecoder().decode(LockHeader.self, from: data),
              header.capsule.generationID == generation.id
        else { return false }
        return (try? SealPackageCrypter.unwrapCEK(header, identity: identity)) != nil
    }
}
