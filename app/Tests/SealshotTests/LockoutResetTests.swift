import XCTest
@testable import Sealshot

/// A store that saves but whose `load()` always fails — standing in for a
/// keychain that is completely unreachable (Touch ID denied, item gone,
/// whatever). `LockoutReset` must complete a full reset without ever calling
/// `load()` — this store proves that: it never touches anything resembling
/// a real keychain.
private final class DenyLoadIdentityStore: IdentityStore {
    private let backing = InMemoryIdentityStore()
    func save(_ identity: IdentityKey) throws { try backing.save(identity) }
    func load() async throws -> IdentityKey? { nil }
    /// Unreachable keychain: promptless reads fail for the same reason.
    func loadWithoutUserPresence() throws -> IdentityKey? { nil }
    func hasStoredIdentity() -> Bool { backing.hasStoredIdentity() }
    func delete() throws { try backing.delete() }
    func save(_ identity: IdentityKey, for generation: KeyGeneration) throws {
        try backing.save(identity, for: generation)
    }
    func load(for generation: KeyGeneration) async throws -> IdentityKey? { nil }
    func hasStoredIdentity(for generation: KeyGeneration) -> Bool {
        backing.hasStoredIdentity(for: generation)
    }
    func delete(for generation: KeyGeneration) throws { try backing.delete(for: generation) }
}

/// Mirrors `KeychainIdentityStore`'s REAL scoping — the no-arg legacy slot
/// and each per-generation slot are backed by DISTINCT keychain accounts
/// (see IdentityStore.swift:88-93), so a no-arg `delete()` clears ONLY the
/// legacy slot. `InMemoryIdentityStore.delete()` deliberately clears
/// everything (legacy + all generations) as a test convenience — which is
/// exactly what would mask a `retireKeyMaterial` that silently skips
/// per-generation deletes (Finding 1): the no-arg `delete()` call still
/// clears the in-memory generations even if `delete(for:)` was never called
/// for them. This store cannot be fooled that way, and it records every
/// `delete(for:)` call so a test can assert every generation was actually
/// enumerated and deleted.
private final class SpyIdentityStore: IdentityStore {
    private var legacy: Data?
    private var perGeneration: [UUID: Data] = [:]
    private(set) var deletedGenerations: [KeyGeneration] = []

    func save(_ identity: IdentityKey) throws { legacy = identity.rawRepresentation }
    func load() async throws -> IdentityKey? {
        guard let raw = legacy else { return nil }
        return try IdentityKey(rawRepresentation: raw)
    }
    /// Same legacy-slot scoping as `load()`; this store has no auth gate.
    func loadWithoutUserPresence() throws -> IdentityKey? {
        guard let raw = legacy else { return nil }
        return try IdentityKey(rawRepresentation: raw)
    }
    func loadWithoutUserPresence(for generation: KeyGeneration) throws -> IdentityKey? {
        guard let raw = perGeneration[generation.id] else { return nil }
        return try IdentityKey(rawRepresentation: raw)
    }
    func hasStoredIdentity() -> Bool { legacy != nil }
    /// Mirrors the real store: the legacy account is DIFFERENT from every
    /// per-generation account, so this clears ONLY the legacy slot.
    func delete() throws { legacy = nil }

    func save(_ identity: IdentityKey, for generation: KeyGeneration) throws {
        perGeneration[generation.id] = identity.rawRepresentation
    }
    func load(for generation: KeyGeneration) async throws -> IdentityKey? {
        guard let raw = perGeneration[generation.id] else { return nil }
        return try IdentityKey(rawRepresentation: raw)
    }
    func hasStoredIdentity(for generation: KeyGeneration) -> Bool {
        perGeneration[generation.id] != nil
    }
    func delete(for generation: KeyGeneration) throws {
        deletedGenerations.append(generation)
        perGeneration[generation.id] = nil
    }

    /// Whether ANYTHING (legacy or any generation) is still stored.
    var hasAnyStoredIdentity: Bool { legacy != nil || !perGeneration.isEmpty }
}

@MainActor
final class LockoutResetTests: XCTestCase {
    var saveFolder: URL!
    var capsuleFolder: URL!
    var store: InMemoryIdentityStore!
    var session: EncryptionSession!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockout-reset-\(UUID().uuidString)", isDirectory: true)
        saveFolder = base.appendingPathComponent("captures")
        capsuleFolder = base.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        store = InMemoryIdentityStore()
        session = EncryptionSession(identityStore: store, capsuleFolder: capsuleFolder,
                                    defaults: UserDefaults(suiteName: "lockout-reset-\(UUID().uuidString)")!)
        session.isEnabled = true
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saveFolder.deletingLastPathComponent())
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeLockedPackage(_ name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pkg = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        // The cheapest honest fixture: `isLocked` only checks for lock.json's
        // presence, so any bytes there count as "locked" for this engine's
        // purposes (it never tries to decrypt).
        try Data("lock-header".utf8).write(to: pkg.appendingPathComponent("lock.json"))
        return pkg
    }

    @discardableResult
    private func makePlaintextPackage(_ name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pkg = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("plaintext".utf8).write(to: pkg.appendingPathComponent("metadata.json"))
        return pkg
    }

    @discardableResult
    private func provisionKeyMaterial(identityStore: IdentityStore? = nil,
                                      session: EncryptionSession? = nil) throws -> KeyGeneration {
        let identityStore = identityStore ?? store!
        let session = session ?? self.session!
        let identity = IdentityKey.generate()
        let generation = KeyGeneration.make(publicKey: identity.publicKey)
        try identityStore.save(identity, for: generation)
        try session.provision(publicKey: identity.publicKey, generation: generation)
        // Adopt (not unlock()) — mirrors EncryptionProvisioner.enable: the
        // identity is already in hand, no need to round-trip the keychain.
        session.adopt(identity)
        try Keystore.create(identity: identity, recoveryCode: RecoveryKey.generateCode(),
                            generation: generation).write(toFolder: saveFolder)
        return generation
    }

    private var deletedFolder: URL { saveFolder.appendingPathComponent("Deleted", isDirectory: true) }
    private var recordingsFolder: URL { saveFolder.appendingPathComponent("Recordings", isDirectory: true) }

    // MARK: - Tests

    func testMixedLockedAndPlaintextAcrossAllThreeFolders() throws {
        try provisionKeyMaterial()
        let rootLocked = try makeLockedPackage("a.seal", in: saveFolder)
        let rootPlain = try makePlaintextPackage("b.seal", in: saveFolder)
        let deletedLocked = try makeLockedPackage("c.seal", in: deletedFolder)
        let deletedPlain = try makePlaintextPackage("d.seal", in: deletedFolder)
        let recLocked = try makeLockedPackage("e.seal", in: recordingsFolder)
        let recPlain = try makePlaintextPackage("f.seal", in: recordingsFolder)

        let summary = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)

        XCTAssertEqual(summary.archivedPackages, 3)
        XCTAssertTrue(summary.failed.isEmpty)

        // Plaintext untouched, still where it was.
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootPlain.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletedPlain.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recPlain.path))

        // Locked packages moved away from their original folders...
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootLocked.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedLocked.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recLocked.path))

        // ...and present, ciphertext intact, under the archive folder.
        for name in ["a.seal", "c.seal", "e.seal"] {
            let dest = summary.archiveFolder.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("lock.json").path))
        }
    }

    func testKeystoreKeyringAndCapsulesAreArchived() throws {
        try provisionKeyMaterial()
        _ = try session.contentKey(for: .history) // materializes history.capsule on disk

        XCTAssertTrue(FileManager.default.fileExists(atPath: saveFolder.appendingPathComponent(Keystore.filename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: capsuleFolder.appendingPathComponent(Keyring.filename).path))

        let summary = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)
        let archive = summary.archiveFolder

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent(Keystore.filename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent(Keyring.filename).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: archive.appendingPathComponent("keys/history.capsule").path))

        // Originals are gone from their source locations (retired / moved out).
        XCTAssertFalse(FileManager.default.fileExists(atPath: saveFolder.appendingPathComponent(Keystore.filename).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: capsuleFolder.appendingPathComponent(Keyring.filename).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: capsuleFolder.appendingPathComponent("history.capsule").path))
    }

    func testSessionDisabledAndLockedStateCoherentAfterReset() async throws {
        try provisionKeyMaterial()
        _ = try await session.unlock()
        XCTAssertTrue(session.isUnlocked)

        _ = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)

        XCTAssertFalse(session.isEnabled)
        XCTAssertFalse(session.isUnlocked)
        XCTAssertNil(session.publicKey)
        XCTAssertNil(session.activeGeneration)
        XCTAssertFalse(store.hasStoredIdentity(), "keychain item retired")
    }

    func testPostsLockStateChangeNotification() throws {
        try provisionKeyMaterial()
        let exp = expectation(forNotification: .encryptionLockStateDidChange, object: session)
        _ = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)
        wait(for: [exp], timeout: 1)
    }

    /// A package that cannot be moved (its containing folder made read-only)
    /// stays in place and is reported in `failed` — everything else, in the
    /// other two package folders and the key-material archive, still proceeds.
    func testPerPackageMoveFailureIsReportedAndEverythingElseProceeds() throws {
        try provisionKeyMaterial()
        let rootLocked = try makeLockedPackage("a.seal", in: saveFolder)
        let deletedLocked = try makeLockedPackage("b.seal", in: deletedFolder)
        let recLocked = try makeLockedPackage("c.seal", in: recordingsFolder)

        // Removing an entry from Deleted/ requires write permission ON Deleted/
        // itself — strip it so moving b.seal out of it fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: deletedFolder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deletedFolder.path)
        }

        let summary = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)

        XCTAssertEqual(summary.archivedPackages, 2, "root + Recordings still archived")
        // Compare resolved paths — /var vs /private/var symlink noise on the
        // temp-dir root would otherwise make an identical path fail ==.
        XCTAssertEqual(summary.failed.map { $0.resolvingSymlinksInPath() },
                       [deletedLocked.resolvingSymlinksInPath()])
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletedLocked.path), "failed package left in place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootLocked.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recLocked.path))

        // Key-material retirement still completed despite the package failure.
        XCTAssertFalse(session.isEnabled)
    }

    /// Proves the reset never depends on a successful keychain read: it must
    /// complete cleanly even against a store whose `load()` always denies.
    func testCompletesWithAKeychainDenyingStore() throws {
        let denyStore = DenyLoadIdentityStore()
        let s = EncryptionSession(identityStore: denyStore, capsuleFolder: capsuleFolder,
                                  defaults: UserDefaults(suiteName: "lockout-reset-deny-\(UUID().uuidString)")!)
        s.isEnabled = true
        try provisionKeyMaterial(identityStore: denyStore, session: s)
        try makeLockedPackage("z.seal", in: saveFolder)

        let summary = try LockoutReset.perform(saveFolder: saveFolder, session: s, identityStore: denyStore)

        XCTAssertEqual(summary.archivedPackages, 1)
        XCTAssertFalse(s.isEnabled)
        XCTAssertFalse(s.isUnlocked)
        XCTAssertFalse(denyStore.hasStoredIdentity(), "keychain-shaped item cleared without ever reading it")
    }

    /// FINDING 1 (discriminating regression guard): `keyring.json` must be
    /// COPIED into the archive, not moved — `retireKeyMaterial` re-reads it
    /// from the capsule folder to enumerate every generation and delete each
    /// one's OWN keychain item. `InMemoryIdentityStore` can't tell "moved out
    /// from under retirement, generations silently skipped" apart from "each
    /// generation genuinely deleted", because its no-arg `delete()` clears
    /// every generation regardless. `SpyIdentityStore` mirrors the real
    /// `KeychainIdentityStore` scoping instead, so it can.
    ///
    /// Confirmed RED against the pre-fix (move-semantics) code: with
    /// keyring.json moved out before `retireKeyMaterial` ran, `Keyring.read`
    /// found nothing in the capsule folder, so `delete(for:)` was called
    /// zero times for both generations — see the fix-round-1 report for the
    /// captured failure output.
    func testRetirementDeletesEveryGenerationsKeychainItemDiscriminating() throws {
        let spy = SpyIdentityStore()
        let s = EncryptionSession(identityStore: spy, capsuleFolder: capsuleFolder,
                                  defaults: UserDefaults(suiteName: "lockout-reset-spy-\(UUID().uuidString)")!)
        s.isEnabled = true

        // Two generations in one keyring: an initial provisioning, then a
        // rotation to a second generation (append-only — see Keyring.appending).
        let gen1 = try provisionKeyMaterial(identityStore: spy, session: s)
        let identity2 = IdentityKey.generate()
        let gen2 = KeyGeneration.make(publicKey: identity2.publicKey)
        try spy.save(identity2, for: gen2)
        try s.provision(publicKey: identity2.publicKey, generation: gen2)
        s.adopt(identity2)

        try makeLockedPackage("z.seal", in: saveFolder)

        let summary = try LockoutReset.perform(saveFolder: saveFolder, session: s, identityStore: spy)

        XCTAssertEqual(Set(spy.deletedGenerations.map { $0.id }), Set([gen1.id, gen2.id]),
                       "retireKeyMaterial must enumerate and delete EVERY generation's own keychain item")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: summary.archiveFolder.appendingPathComponent(Keyring.filename).path),
            "keyring.json must be present in the archive")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: capsuleFolder.appendingPathComponent(Keyring.filename).path),
            "capsule folder must not retain keyring.json once retirement has run")
    }

    /// FINDING 2: a failure archiving the key-file step (keystore/keyring/
    /// capsules) must THROW and leave the session's key material completely
    /// untouched — no retirement may run against an incomplete archive.
    func testFatalKeyArchiveFailureLeavesKeyMaterialIntact() throws {
        let spy = SpyIdentityStore()
        let s = EncryptionSession(identityStore: spy, capsuleFolder: capsuleFolder,
                                  defaults: UserDefaults(suiteName: "lockout-reset-fatal-\(UUID().uuidString)")!)
        s.isEnabled = true
        try provisionKeyMaterial(identityStore: spy, session: s)
        try makeLockedPackage("z.seal", in: saveFolder)

        // Pre-create the archive folder read-only: `perform`'s own
        // `createDirectory` no-ops on an already-existing folder, but the
        // keystore.json move into it then fails for lack of write permission.
        let archiveFolder = saveFolder.appendingPathComponent(Quarantine.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: archiveFolder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: archiveFolder.path)
        }

        XCTAssertThrowsError(
            try LockoutReset.perform(saveFolder: saveFolder, session: s, identityStore: spy))

        // The invariants that matter: key material is intact and retirement
        // never ran. (Packages may or may not have moved before the throw —
        // that's not part of the contract this test is protecting.)
        XCTAssertTrue(s.isEnabled, "must not disable encryption on a fatal archive failure")
        XCTAssertTrue(spy.deletedGenerations.isEmpty, "retirement must never run past a fatal archive failure")
        XCTAssertTrue(spy.hasAnyStoredIdentity, "keychain-shaped item must survive intact")
    }

    /// FINDING 3: keystore.json can legitimately be absent (e.g. removed by
    /// an earlier auto-repair pass) even though the rest of the key material
    /// is provisioned. `perform` must still succeed: packages archived, no
    /// keystore.json in the archive, session disabled, retirement still runs.
    func testSucceedsWhenKeystoreJSONIsMissing() throws {
        try provisionKeyMaterial()
        try FileManager.default.removeItem(at: saveFolder.appendingPathComponent(Keystore.filename))
        try makeLockedPackage("z.seal", in: saveFolder)

        let summary = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)

        XCTAssertEqual(summary.archivedPackages, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: summary.archiveFolder.appendingPathComponent(Keystore.filename).path))
        XCTAssertFalse(session.isEnabled)
        XCTAssertFalse(store.hasStoredIdentity(), "retirement still ran despite the missing keystore.json")
    }

    /// FINDING (fix round 2, discriminating): two full lockout cycles in a
    /// row — reset, re-enable encryption with a fresh identity/keystore/
    /// keyring, get locked out again, reset a second time — must NOT
    /// destroy round 1's archived restore seeds. `Locked-Unrecoverable/`
    /// accumulates packages collision-safely already (see `Quarantine`);
    /// the keystore/keyring/capsule seeds archived alongside them must get
    /// the exact same treatment, or round 1's packages become permanently
    /// unrestorable the moment a second cycle happens.
    ///
    /// Confirmed RED against the pre-fix code (fixed-path `replace()` that
    /// `removeItem`s the destination first): round 2's `keystore.json` /
    /// `keyring.json` silently clobbered round 1's — see the fix-round-2
    /// report for the captured failure output.
    func testRepeatedResetsPreserveAllRoundsRestoreSeedsDiscriminating() throws {
        // Round 1: provision, lock a package, reset.
        try provisionKeyMaterial()
        try makeLockedPackage("round1.seal", in: saveFolder)
        let summary1 = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)
        let archive = summary1.archiveFolder

        let round1KeystoreURL = archive.appendingPathComponent(Keystore.filename)
        let round1KeyringURL = archive.appendingPathComponent(Keyring.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: round1KeystoreURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: round1KeyringURL.path))
        let round1KeystoreBytes = try Data(contentsOf: round1KeystoreURL)
        let round1KeyringBytes = try Data(contentsOf: round1KeyringURL)

        // Round 2: re-enable encryption with a brand-new identity/generation
        // (mirrors the user turning Enhanced Security back on after round
        // 1's reset), lock a NEW package, then get reset a second time.
        session.isEnabled = true
        try provisionKeyMaterial()
        try makeLockedPackage("round2.seal", in: saveFolder)
        let summary2 = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)

        XCTAssertEqual(summary2.archiveFolder.path, archive.path, "same archive folder reused across cycles")

        // Both rounds' packages survive.
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent("round1.seal").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent("round2.seal").path))

        // Round 1's keystore.json must still be there, byte-identical to
        // what was captured right after round 1 — never touched by round 2.
        XCTAssertTrue(FileManager.default.fileExists(atPath: round1KeystoreURL.path),
                      "round 1's keystore.json must survive a second reset")
        XCTAssertEqual(try Data(contentsOf: round1KeystoreURL), round1KeystoreBytes,
                       "round 1's archived keystore.json must be byte-identical after round 2's reset")

        // Round 2's keystore must be archived too, under a unique suffixed
        // name (mirrors Quarantine.uniqueDestination's -1/-2/… idiom).
        let round2KeystoreURL = archive.appendingPathComponent("keystore-1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: round2KeystoreURL.path),
                      "round 2's keystore must be archived under a unique suffixed name, not overwrite round 1's")

        // Same story for keyring.json.
        XCTAssertTrue(FileManager.default.fileExists(atPath: round1KeyringURL.path),
                      "round 1's keyring.json must survive a second reset")
        XCTAssertEqual(try Data(contentsOf: round1KeyringURL), round1KeyringBytes,
                       "round 1's archived keyring.json must be byte-identical after round 2's reset")
        let round2KeyringURL = archive.appendingPathComponent("keyring-1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: round2KeyringURL.path),
                      "round 2's keyring must be archived under a unique suffixed name, not overwrite round 1's")
    }
}
