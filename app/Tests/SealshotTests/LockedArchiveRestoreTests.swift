import XCTest
import CryptoKit
@testable import Sealshot

/// Round-trip tests for `LockedArchiveRestore` — the engine that reverses a
/// `LockoutReset` once the user finds their recovery code again. The suite
/// builds REAL encrypted fixtures (actual HPKE capsules, actual sealed
/// entries) because unlike `LockoutReset` — which never decrypts anything —
/// the restore engine's whole contract is cryptographic: the typed code must
/// select the right archived keystore, and only packages the recovered
/// identity can actually unwrap may leave the archive.
@MainActor
final class LockedArchiveRestoreTests: XCTestCase {
    var saveFolder: URL!
    var capsuleFolder: URL!
    var store: InMemoryIdentityStore!
    var session: EncryptionSession!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("locked-archive-restore-\(UUID().uuidString)", isDirectory: true)
        saveFolder = base.appendingPathComponent("captures")
        capsuleFolder = base.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        store = InMemoryIdentityStore()
        session = EncryptionSession(
            identityStore: store, capsuleFolder: capsuleFolder,
            defaults: UserDefaults(suiteName: "locked-archive-restore-\(UUID().uuidString)")!)
        session.isEnabled = true
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saveFolder.deletingLastPathComponent())
    }

    // MARK: - Fixtures

    /// One full encryption cycle's key material: identity + generation +
    /// recovery code, saved/provisioned/adopted exactly the way
    /// `EncryptionProvisioner.enable` does, with the keystore escrowing the
    /// code written to the save-folder root.
    struct Cycle {
        let identity: IdentityKey
        let generation: KeyGeneration
        let code: String
    }

    @discardableResult
    private func provisionCycle() throws -> Cycle {
        let identity = IdentityKey.generate()
        let generation = KeyGeneration.make(publicKey: identity.publicKey)
        let code = RecoveryKey.generateCode()
        try store.save(identity, for: generation)
        try session.provision(publicKey: identity.publicKey, generation: generation)
        session.adopt(identity)
        try Keystore.create(identity: identity, recoveryCode: code, generation: generation)
            .write(toFolder: saveFolder)
        return Cycle(identity: identity, generation: generation, code: code)
    }

    /// A REAL locked package: entries sealed with a fresh CEK wrapped to the
    /// cycle's public key, lock.json carrying the v2 capsule with the cycle's
    /// generation id — everything the restore engine's reachability check and
    /// unwrap probe will actually exercise.
    @discardableResult
    private func makeRealLockedPackage(_ name: String, in folder: URL,
                                       cycle: Cycle) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pkg = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let sealed = try SealPackageCrypter.sealEntries(
            ["metadata.json": Data("secret-\(name)".utf8)],
            publicKey: cycle.identity.publicKey, generation: cycle.generation)
        for (entryName, data) in sealed.entries {
            try data.write(to: pkg.appendingPathComponent(entryName))
        }
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

    private var deletedFolder: URL { saveFolder.appendingPathComponent("Deleted", isDirectory: true) }
    private var archiveFolder: URL {
        saveFolder.appendingPathComponent(Quarantine.folderName, isDirectory: true)
    }

    /// Sorted relative paths of everything under the archive — for
    /// "untouched" assertions.
    private func archiveListing() -> [String] {
        guard let e = FileManager.default.enumerator(
            at: archiveFolder, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { ($0 as? URL)?.path }
            .map { $0.replacingOccurrences(of: archiveFolder.path, with: "") }
            .sorted()
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Tests

    /// The canonical reversal: provision → lock packages → guided reset →
    /// restore with the right code. Packages return to the save-folder root
    /// (still encrypted, but openable again), the session is re-enabled and
    /// unlocked under the recovered generation, the keystore/keyring/store
    /// capsules are live again, and the archive no longer holds this cycle's
    /// seeds or packages.
    func testRoundTripRestoresPackagesSessionAndSeeds() async throws {
        let cycle = try provisionCycle()
        _ = try session.contentKey(for: .history)   // materialize history.capsule
        try makeRealLockedPackage("a.seal", in: saveFolder, cycle: cycle)
        try makeRealLockedPackage("c.seal", in: deletedFolder, cycle: cycle)
        let plain = try makePlaintextPackage("b.seal", in: saveFolder)

        let reset = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)
        XCTAssertEqual(reset.archivedPackages, 2)
        XCTAssertFalse(session.isEnabled)

        let summary = try await LockedArchiveRestore.restore(
            code: cycle.code, saveFolder: saveFolder, session: session, identityStore: store)

        XCTAssertEqual(summary.restoredPackages, 2)
        XCTAssertEqual(summary.stillArchived, 0)
        XCTAssertTrue(summary.failed.isEmpty)
        XCTAssertFalse(summary.displacedLiveCycle,
                       "a plain single-cycle round-trip displaces nothing live")

        // Packages back in the save-folder ROOT (c.seal came from Deleted/ —
        // returning to root is the documented, accepted behavior), still
        // encrypted (their ciphertext was never touched).
        let restoredA = saveFolder.appendingPathComponent("a.seal")
        let restoredC = saveFolder.appendingPathComponent("c.seal")
        XCTAssertTrue(fileExists(restoredA))
        XCTAssertTrue(fileExists(restoredC))
        XCTAssertTrue(SealPackageCrypter.isLocked(restoredA))
        XCTAssertTrue(SealPackageCrypter.isLocked(restoredC))
        XCTAssertTrue(fileExists(plain), "plaintext package untouched throughout")

        // Session state: enabled, unlocked, active under the recovered generation.
        XCTAssertTrue(session.isEnabled)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertEqual(session.activeGeneration?.id, cycle.generation.id)

        // Seeds are live again: keystore at the root, keyring active on the
        // recovered generation, store capsule back so contentKey works.
        XCTAssertEqual(Keystore.read(fromFolder: saveFolder)?.generation.id, cycle.generation.id)
        XCTAssertEqual(Keyring.read(fromFolder: capsuleFolder)?.active?.generation.id, cycle.generation.id)
        XCTAssertNotNil(try session.contentKey(for: .history))

        // The restored package actually opens with the recovered identity.
        let headerData = try Data(contentsOf: restoredA.appendingPathComponent(LockHeader.filename))
        let header = try JSONDecoder().decode(LockHeader.self, from: headerData)
        let identity = try XCTUnwrap(session.unlockedIdentityForDrain())
        let cek = try SealPackageCrypter.unwrapCEK(header, identity: identity)
        let sealedEntry = try Data(contentsOf: restoredA.appendingPathComponent("metadata.json"))
        XCTAssertEqual(try SealedBlob.open(sealedEntry, with: cek), Data("secret-a.seal".utf8))

        // Archive is empty of this cycle's seeds and packages.
        let remaining = archiveListing()
        XCTAssertFalse(remaining.contains { $0.contains("keystore") },
                       "restored cycle's keystore must leave the archive")
        XCTAssertFalse(remaining.contains { $0.contains("keyring") },
                       "restored cycle's keyring seed must leave the archive")
        XCTAssertFalse(remaining.contains { $0.contains("history") && $0.contains("capsule") },
                       "restored store capsule must leave the archive")
        XCTAssertFalse(remaining.contains { $0.hasSuffix(".seal") })
    }

    /// A wrong code must throw the typed error and leave the archive — and
    /// the disabled session — completely untouched.
    func testWrongCodeThrowsTypedErrorAndArchiveUntouched() async throws {
        let cycle = try provisionCycle()
        try makeRealLockedPackage("a.seal", in: saveFolder, cycle: cycle)
        _ = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)
        let before = archiveListing()
        XCTAssertFalse(before.isEmpty)

        let wrongCode = RecoveryKey.generateCode()
        XCTAssertNotEqual(wrongCode, cycle.code)

        do {
            _ = try await LockedArchiveRestore.restore(
                code: wrongCode, saveFolder: saveFolder, session: session, identityStore: store)
            XCTFail("wrong code must throw")
        } catch let error as LockedArchiveRestore.Error {
            XCTAssertEqual(error, .codeDoesNotMatch)
        }

        XCTAssertEqual(archiveListing(), before, "wrong code must not touch the archive")
        XCTAssertFalse(session.isEnabled)
        XCTAssertFalse(session.isUnlocked)
        XCTAssertFalse(store.hasStoredIdentity(for: cycle.generation),
                       "no identity may be persisted on a failed match")
    }

    /// No archive (or an archive without any keystore seed) is its own typed
    /// error — the UI says "no archived backup" instead of "wrong code".
    func testMissingArchiveThrowsNoArchivedKeystore() async throws {
        do {
            _ = try await LockedArchiveRestore.restore(
                code: "AAAAA-AAAAA-AAAAA-AAAAA-AAAAA",
                saveFolder: saveFolder, session: session, identityStore: store)
            XCTFail("missing archive must throw")
        } catch let error as LockedArchiveRestore.Error {
            XCTAssertEqual(error, .noArchivedKeystore)
        }
    }

    /// TWO full lockout cycles (reset A, re-enable, reset B): the archive
    /// holds both cycles' packages and both cycles' suffixed seeds — and the
    /// suffix numbers must NOT be trusted to pair keystores with keyrings.
    /// Code B restores ONLY B's packages (A's are reported as still
    /// archived); code A afterwards brings A's back too.
    func testTwoCycleRestoreIsGenerationScoped() async throws {
        // Cycle A.
        let cycleA = try provisionCycle()
        try makeRealLockedPackage("round1.seal", in: saveFolder, cycle: cycleA)
        _ = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)

        // Cycle B: user re-enabled encryption, then got locked out again.
        session.isEnabled = true
        let cycleB = try provisionCycle()
        try makeRealLockedPackage("round2.seal", in: saveFolder, cycle: cycleB)
        _ = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)

        // Restore with code B: only B's package comes back; A's stays and is
        // reported so the UI can say "1 item from another reset remains".
        let summaryB = try await LockedArchiveRestore.restore(
            code: cycleB.code, saveFolder: saveFolder, session: session, identityStore: store)
        XCTAssertEqual(summaryB.restoredPackages, 1)
        XCTAssertEqual(summaryB.stillArchived, 1)
        XCTAssertTrue(summaryB.failed.isEmpty)
        XCTAssertTrue(fileExists(saveFolder.appendingPathComponent("round2.seal")))
        XCTAssertFalse(fileExists(saveFolder.appendingPathComponent("round1.seal")))
        XCTAssertTrue(fileExists(archiveFolder.appendingPathComponent("round1.seal")),
                      "the other cycle's package stays archived")
        XCTAssertEqual(session.activeGeneration?.id, cycleB.generation.id)

        // round2.seal actually opens with the recovered (B) identity —
        // decrypt-level, not just fileExists.
        let round2 = saveFolder.appendingPathComponent("round2.seal")
        let header2Data = try Data(contentsOf: round2.appendingPathComponent(LockHeader.filename))
        let header2 = try JSONDecoder().decode(LockHeader.self, from: header2Data)
        let identityAfterB = try XCTUnwrap(session.unlockedIdentityForDrain())
        let cek2 = try SealPackageCrypter.unwrapCEK(header2, identity: identityAfterB)
        let sealedEntry2 = try Data(contentsOf: round2.appendingPathComponent("metadata.json"))
        XCTAssertEqual(try SealedBlob.open(sealedEntry2, with: cek2), Data("secret-round2.seal".utf8))
        XCTAssertEqual(Keystore.read(fromFolder: saveFolder)?.generation.id, cycleB.generation.id,
                       "canonical keystore.json escrows the active generation")
        // Exactly one keystore seed (cycle A's) remains for a later restore.
        XCTAssertEqual(archiveListing().filter { $0.contains("keystore") }.count, 1)

        // Restore with code A: A's package comes back too.
        let summaryA = try await LockedArchiveRestore.restore(
            code: cycleA.code, saveFolder: saveFolder, session: session, identityStore: store)
        XCTAssertEqual(summaryA.restoredPackages, 1)
        XCTAssertEqual(summaryA.stillArchived, 0)
        XCTAssertTrue(fileExists(saveFolder.appendingPathComponent("round1.seal")))
        XCTAssertEqual(session.activeGeneration?.id, cycleA.generation.id)
        // The canonical keystore.json must always escrow the ACTIVE
        // generation — View Recovery Code and the consistency check read only
        // that file. Cycle B's keystore is displaced to a suffixed name (in
        // the archive — never deleted), not left shadowing the active one.
        XCTAssertEqual(Keystore.read(fromFolder: saveFolder)?.generation.id, cycleA.generation.id,
                       "canonical keystore.json escrows the active generation")

        // round1.seal actually opens with the recovered (A) identity —
        // decrypt-level, not just fileExists.
        let round1 = saveFolder.appendingPathComponent("round1.seal")
        let header1Data = try Data(contentsOf: round1.appendingPathComponent(LockHeader.filename))
        let header1 = try JSONDecoder().decode(LockHeader.self, from: header1Data)
        let identityAfterA = try XCTUnwrap(session.unlockedIdentityForDrain())
        let cek1 = try SealPackageCrypter.unwrapCEK(header1, identity: identityAfterA)
        let sealedEntry1 = try Data(contentsOf: round1.appendingPathComponent("metadata.json"))
        XCTAssertEqual(try SealedBlob.open(sealedEntry1, with: cek1), Data("secret-round1.seal".utf8))

        // Both generations stay reachable afterwards — the keyring carries
        // both records and both identities are persisted, so neither cycle's
        // packages went dark.
        let reachable = await session.reachableIdentities()
        XCTAssertNotNil(reachable[cycleA.generation.id])
        XCTAssertNotNil(reachable[cycleB.generation.id])
    }

    /// A package that cannot be moved back (archive folder made read-only)
    /// is reported in `failed` and NOTHING is deleted; the engine still
    /// completes and the session still comes back up.
    func testPartialMoveFailureIsReportedAndRestoreContinues() async throws {
        let cycle = try provisionCycle()
        try makeRealLockedPackage("a.seal", in: saveFolder, cycle: cycle)
        try makeRealLockedPackage("b.seal", in: saveFolder, cycle: cycle)
        _ = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)

        // Read-only archive folder: nothing can be moved OUT of it (moving an
        // entry requires write permission on its parent).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: archiveFolder.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: archiveFolder.path)
        }

        let summary = try await LockedArchiveRestore.restore(
            code: cycle.code, saveFolder: saveFolder, session: session, identityStore: store)

        XCTAssertEqual(summary.restoredPackages, 0)
        XCTAssertEqual(summary.stillArchived, 0)
        XCTAssertEqual(Set(summary.failed.map { $0.lastPathComponent }), Set(["a.seal", "b.seal"]))

        // Nothing deleted: both packages still in the archive, ciphertext intact.
        XCTAssertTrue(fileExists(archiveFolder.appendingPathComponent("a.seal/lock.json")))
        XCTAssertTrue(fileExists(archiveFolder.appendingPathComponent("b.seal/lock.json")))

        // The key-material side of the restore still completed.
        XCTAssertTrue(session.isEnabled)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertEqual(session.activeGeneration?.id, cycle.generation.id)
    }

    /// A keystore already canonical at the save-folder root — a fully live,
    /// never-reset cycle, not another archived seed — must be displaced INTO
    /// THE ARCHIVE when a different cycle is restored, never to the
    /// save-folder root: `restore()`'s candidate scan only ever reads the
    /// archive, so a root-level displacement would silently strand that
    /// cycle, permanently unrestorable through the UI even though nothing
    /// was deleted.
    func testDisplacedLiveKeystoreStaysRestorableFromArchive() async throws {
        // Cycle A: locked out and archived.
        let cycleA = try provisionCycle()
        try makeRealLockedPackage("a.seal", in: saveFolder, cycle: cycleA)
        _ = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)

        // Cycle B: re-enabled and fully LIVE — its keystore.json is
        // canonical at the save-folder root, never reset. b.seal is
        // quarantined directly (independent of any keystore reset) so B has
        // something archived to reclaim once its own code is used again.
        session.isEnabled = true
        let cycleB = try provisionCycle()
        let pkgB = try makeRealLockedPackage("b.seal", in: saveFolder, cycle: cycleB)
        try Quarantine.move(pkgB, saveFolder: saveFolder)
        XCTAssertEqual(Keystore.read(fromFolder: saveFolder)?.generation.id, cycleB.generation.id,
                       "cycle B's keystore.json is canonical/live before the restore")

        // Restore A while B's keystore is still live/canonical at the root:
        // B's keystore must be displaced somewhere B's own restore can
        // still find it. Restoration is GENERATION-SCOPED: only a.seal (A's
        // own package) comes back here — b.seal belongs to B's generation,
        // so even though B's identity is independently reachable via the
        // keyring's stored keychain item (see `reachableIdentities()`), it
        // must stay archived and counted in `stillArchived` rather than
        // returning to a library where only A's identity is adopted.
        let summaryA = try await LockedArchiveRestore.restore(
            code: cycleA.code, saveFolder: saveFolder, session: session, identityStore: store)
        XCTAssertEqual(summaryA.restoredPackages, 1)
        XCTAssertEqual(summaryA.stillArchived, 1)
        XCTAssertEqual(session.activeGeneration?.id, cycleA.generation.id)
        XCTAssertTrue(fileExists(saveFolder.appendingPathComponent("a.seal")))
        XCTAssertFalse(fileExists(saveFolder.appendingPathComponent("b.seal")),
                       "b.seal belongs to B's generation and must stay archived until B's own restore")
        XCTAssertTrue(summaryA.displacedLiveCycle,
                      "B's live, canonical keystore had to be displaced to restore A")

        XCTAssertTrue(archiveListing().contains { $0.contains("keystore") },
                      "B's displaced keystore must land in the archive, not the save-folder root")
        let strayAtRoot = ((try? FileManager.default.contentsOfDirectory(
            at: saveFolder, includingPropertiesForKeys: nil)) ?? [])
            .contains { $0.lastPathComponent.hasPrefix("keystore") && $0.lastPathComponent != Keystore.filename }
        XCTAssertFalse(strayAtRoot, "no loose keystore-N.json may be left at the save-folder root")

        // B's code must still work THROUGH THE UI — restore(code: B) must
        // match and adopt B rather than throw `.noArchivedKeystore` /
        // `.codeDoesNotMatch`. This is the round-trip the design promises:
        // a cycle whose keystore got displaced while restoring another one
        // must never become permanently unrestorable — and B's own package,
        // left behind by A's generation-scoped restore above, now comes back.
        let summaryB = try await LockedArchiveRestore.restore(
            code: cycleB.code, saveFolder: saveFolder, session: session, identityStore: store)
        XCTAssertEqual(summaryB.restoredPackages, 1)
        XCTAssertEqual(session.activeGeneration?.id, cycleB.generation.id)
        XCTAssertEqual(Keystore.read(fromFolder: saveFolder)?.generation.id, cycleB.generation.id,
                       "canonical keystore.json escrows the active (B) generation again")
        XCTAssertTrue(fileExists(saveFolder.appendingPathComponent("b.seal")),
                      "b.seal comes back only now, on B's own restore")
        XCTAssertTrue(summaryB.displacedLiveCycle,
                      "A's keystore is now the live/canonical one and must be displaced to restore B")
    }

    /// The occupied-slot branch of the store-capsule step (historically
    /// untested): cycle A creates its own store capsule and seals a probe
    /// blob under that content key; cycle B is re-provisioned afterward and
    /// also touches `contentKey(.history)`, so B's capsule occupies the live
    /// slot by the time A is restored. Pins the re-wrap's actual contract:
    /// A's own content key comes back live (the probe decrypts, byte for
    /// byte) and the occupant (B's) capsule is DISPLACED into the archive
    /// rather than clobbered, so IT round-trips too when B is restored
    /// afterward.
    func testOccupiedSlotCapsuleDisplacesOccupantAndBothCyclesRoundTrip() async throws {
        let cycleA = try provisionCycle()
        let cekA = try XCTUnwrap(session.contentKey(for: .history))
        let probeA = try SealedBlob.seal(Data("probe-a".utf8), with: cekA)
        _ = try LockoutReset.perform(saveFolder: saveFolder, session: session, identityStore: store)

        // Cycle B: re-provisioned; touching contentKey mints a FRESH capsule
        // (the slot was emptied by A's retirement) — this is what occupies
        // the slot when A is restored below.
        session.isEnabled = true
        let cycleB = try provisionCycle()
        let cekB = try XCTUnwrap(session.contentKey(for: .history))
        let probeB = try SealedBlob.seal(Data("probe-b".utf8), with: cekB)

        // Restore A while B's capsule occupies the slot — the occupied-slot
        // branch, never executed by any other test.
        let summaryA = try await LockedArchiveRestore.restore(
            code: cycleA.code, saveFolder: saveFolder, session: session, identityStore: store)
        XCTAssertTrue(summaryA.displacedLiveCycle,
                      "B's occupied capsule had to be displaced to restore A")

        // A's own history content key is live again — the probe sealed
        // under it (before the reset) decrypts, byte for byte.
        let keyAfterA = try XCTUnwrap(session.contentKey(for: .history))
        XCTAssertEqual(try SealedBlob.open(probeA, with: keyAfterA), Data("probe-a".utf8))

        // B's capsule was DISPLACED into the archive, not clobbered — still
        // a legitimate restorable seed for B's own cycle.
        XCTAssertTrue(archiveListing().contains {
            $0.contains("keys") && $0.contains("history") && $0.contains("capsule")
        }, "the occupied capsule must be preserved in the archive, not overwritten")

        // Restoring B afterward brings ITS content key back live too.
        _ = try await LockedArchiveRestore.restore(
            code: cycleB.code, saveFolder: saveFolder, session: session, identityStore: store)
        let keyAfterB = try XCTUnwrap(session.contentKey(for: .history))
        XCTAssertEqual(try SealedBlob.open(probeB, with: keyAfterB), Data("probe-b".utf8))
    }
}
