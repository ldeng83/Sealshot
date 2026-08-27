import XCTest
@testable import Sealshot

/// Wraps InMemoryIdentityStore and counts `load()` calls — in production the
/// keychain store's load() is the Touch ID / password prompt, so a count of
/// zero means "the user was never auth-prompted".
private final class LoadCountingIdentityStore: IdentityStore {
    private let backing = InMemoryIdentityStore()
    private(set) var loadCount = 0
    func save(_ identity: IdentityKey) throws { try backing.save(identity) }
    func load() async throws -> IdentityKey? {
        loadCount += 1
        return try await backing.load()
    }
    /// Not an auth prompt, so it deliberately does NOT bump `loadCount`.
    func loadWithoutUserPresence() throws -> IdentityKey? {
        try backing.loadWithoutUserPresence()
    }
    func hasStoredIdentity() -> Bool { backing.hasStoredIdentity() }
    func delete() throws { try backing.delete() }
}

@MainActor
final class EncryptionProvisionerTests: XCTestCase {
    var saveFolder: URL!
    var capsuleFolder: URL!
    var store: InMemoryIdentityStore!
    var session: EncryptionSession!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov-\(UUID().uuidString)", isDirectory: true)
        saveFolder = base.appendingPathComponent("captures")
        capsuleFolder = base.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        store = InMemoryIdentityStore()
        session = EncryptionSession(identityStore: store, capsuleFolder: capsuleFolder,
                                    defaults: UserDefaults(suiteName: "prov-\(UUID().uuidString)")!)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saveFolder.deletingLastPathComponent())
    }

    // MARK: - Test 1: enable happy path

    func testEnableProvisionsEverythingAndMigrates() async throws {
        // One plaintext package to migrate.
        let pkg = saveFolder.appendingPathComponent("a.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("{\"version\":4}".utf8).write(to: pkg.appendingPathComponent("manifest.json"))

        let code = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }

        XCTAssertFalse(code.isEmpty)
        XCTAssertTrue(session.isEnabled)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertNotNil(session.publicKey)
        XCTAssertNotNil(Keystore.read(fromFolder: saveFolder))
        XCTAssertTrue(SealPackageCrypter.isLocked(pkg))
        // Recovery code actually recovers the identity.
        let keystore = try XCTUnwrap(Keystore.read(fromFolder: saveFolder))
        XCTAssertNoThrow(try RecoveryKey.recover(escrow: keystore.escrow, code: code))
    }

    // MARK: - Test 1c: enable migrates recordings too

    func testEnableMigratesExistingRecordings() async throws {
        let recordings = saveFolder.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let mov = recordings.appendingPathComponent("clip.mov")
        try Data((0..<3000).map { UInt8($0 % 251) }).write(to: mov)

        _ = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }

        XCTAssertFalse(FileManager.default.fileExists(atPath: mov.path),
                       "plaintext recording removed after enable")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recordings.appendingPathComponent("clip.sealrec").path),
                      "recording encrypted to .sealrec by enable")
    }

    func testEnableAndDisableMigrateCollectionStorageWithSecurityMode() async throws {
        let directory = capsuleFolder.deletingLastPathComponent()
        let plainURL = CollectionStore.plaintextURL(in: directory)
        let sealedURL = CollectionStore.sealedURL(in: directory)
        let plain = CollectionStore(fileURL: plainURL, key: nil)
        _ = try await plain.create(name: "Test", now: Date(timeIntervalSince1970: 1_000))

        _ = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }

        XCTAssertFalse(FileManager.default.fileExists(atPath: plainURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedURL.path))
        let key = try XCTUnwrap(try session.contentKey(for: .libraryIndex))
        let encrypted = CollectionStore(fileURL: sealedURL, key: key)
        let encryptedNames = await encrypted.all().map(\.name)
        XCTAssertEqual(encryptedNames, ["Test"])

        await EncryptionProvisioner.disable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: plainURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealedURL.path))
        let decrypted = CollectionStore(fileURL: plainURL, key: nil)
        let decryptedNames = await decrypted.all().map(\.name)
        XCTAssertEqual(decryptedNames, ["Test"])
    }

    // MARK: - Test 1b: enable must not auth-prompt

    func testEnableNeverCallsIdentityStoreLoad() async throws {
        // The provisioner just generated the identity — unlocking the session
        // by re-loading it from the (keychain) store would auth-prompt the
        // user mid-enable. The session must adopt the in-memory key instead.
        let counting = LoadCountingIdentityStore()
        let session = EncryptionSession(
            identityStore: counting,
            capsuleFolder: capsuleFolder,
            defaults: UserDefaults(suiteName: "prov-\(UUID().uuidString)")!)

        _ = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: counting) { _, _ in }

        XCTAssertEqual(counting.loadCount, 0, "enable must not trigger the load() auth gate")
        XCTAssertTrue(session.isUnlocked, "session must still come out unlocked")
        XCTAssertNotNil(session.publicKey)
    }

    // MARK: - Test 2: enable alreadyEnabled

    func testEnableTwiceThrows() async throws {
        _ = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }
        do {
            _ = try await EncryptionProvisioner.enable(
                saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }
            XCTFail("expected .alreadyEnabled to be thrown")
        } catch {
            guard case EncryptionProvisioner.Error.alreadyEnabled = error else {
                return XCTFail("expected .alreadyEnabled, got \(error)")
            }
        }
    }

    // MARK: - Test 3: disable happy path

    func testDisableDecryptsAndRetires() async throws {
        let pkg = saveFolder.appendingPathComponent("a.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("{\"version\":4}".utf8).write(to: pkg.appendingPathComponent("manifest.json"))
        _ = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }

        await EncryptionProvisioner.disable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }

        XCTAssertFalse(session.isEnabled)
        XCTAssertFalse(SealPackageCrypter.isLocked(pkg))
        let storeLoaded = try await store.load()
        XCTAssertNil(storeLoaded)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: saveFolder.appendingPathComponent(Keystore.filename).path))
    }

    // MARK: - Test 3b: always-can-disable quarantines when no key is reachable

    func testDisableQuarantinesWhenNoIdentityReachable() async throws {
        let pkg = saveFolder.appendingPathComponent("a.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("{\"version\":4}".utf8).write(to: pkg.appendingPathComponent("manifest.json"))
        _ = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }

        // Simulate the locked-out state: session locked + identity gone.
        session.lock()
        try store.delete()

        let summary = await EncryptionProvisioner.disable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }

        // Always-can-disable: encryption turns off even with no reachable key.
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(summary.decrypted, 0)
        XCTAssertEqual(summary.quarantined, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pkg.path), "package moved out")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: saveFolder.appendingPathComponent("\(Quarantine.folderName)/a.seal").path),
                      "package preserved in quarantine")
        // Keys retired.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: saveFolder.appendingPathComponent(Keystore.filename).path))
        XCTAssertNil(Keyring.read(fromFolder: capsuleFolder))
    }

    // MARK: - Test 4: migrationIncomplete keeps flag+session; resumeMigration fixes it

    func testEnableWithTamperedPackageKeepsFlagAndSessionThenResumeFixes() async throws {
        // Good package — plaintext.
        let good = saveFolder.appendingPathComponent("good.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try Data("{\"version\":4}".utf8).write(to: good.appendingPathComponent("manifest.json"))

        // Bad package — has a subdir that rawEntries() rejects (non-regular file).
        let bad = saveFolder.appendingPathComponent("bad.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{\"version\":4}".utf8).write(to: bad.appendingPathComponent("manifest.json"))
        try FileManager.default.createDirectory(
            at: bad.appendingPathComponent("weird-subdir"), withIntermediateDirectories: true)

        // enable should throw migrationIncomplete (one package failed).
        do {
            _ = try await EncryptionProvisioner.enable(
                saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }
            XCTFail("expected migrationIncomplete to be thrown")
        } catch {
            guard case SealMigrator.Error.migrationIncomplete = error else {
                return XCTFail("expected migrationIncomplete, got \(error)")
            }
        }

        // Critical: flag MUST stay ON, session MUST stay unlocked,
        // good package MUST be locked, bad package stays plain.
        XCTAssertTrue(session.isEnabled, "flag must stay ON after partial migration")
        XCTAssertTrue(session.isUnlocked, "session must stay unlocked after partial migration")
        XCTAssertNotNil(session.publicKey)
        XCTAssertTrue(SealPackageCrypter.isLocked(good), "good package must be locked")
        XCTAssertFalse(SealPackageCrypter.isLocked(bad), "bad package stays plain (failed)")

        // Calling enable again must throw alreadyEnabled (not allowed).
        do {
            _ = try await EncryptionProvisioner.enable(
                saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }
            XCTFail("expected .alreadyEnabled to be thrown")
        } catch {
            guard case EncryptionProvisioner.Error.alreadyEnabled = error else {
                return XCTFail("expected .alreadyEnabled on second enable, got \(error)")
            }
        }

        // Fix the bad package: remove the subdir, leaving only the manifest.
        try FileManager.default.removeItem(at: bad.appendingPathComponent("weird-subdir"))

        // resumeMigration re-runs encryptAll for the straggler.
        try await EncryptionProvisioner.resumeMigration(saveFolder: saveFolder, session: session) { _, _ in }
        XCTAssertTrue(SealPackageCrypter.isLocked(bad), "bad package now locked after resume")
        XCTAssertTrue(session.isEnabled, "flag still ON after resume")
    }

    // MARK: - Recovery code: view + regenerate

    func testViewRecoveryCodeReturnsTheEnableCode() async throws {
        let code = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }
        let viewed = await EncryptionProvisioner.viewRecoveryCode(saveFolder: saveFolder, session: session)
        XCTAssertEqual(viewed, code)
    }

    func testRegenerateRecoveryCodeRotatesAndInvalidatesOld() async throws {
        let oldCode = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }
        let regenerated = await EncryptionProvisioner.regenerateRecoveryCode(
            saveFolder: saveFolder, session: session)
        let newCode = try XCTUnwrap(regenerated)
        XCTAssertNotEqual(newCode, oldCode)

        let keystore = try XCTUnwrap(Keystore.read(fromFolder: saveFolder))
        XCTAssertNoThrow(try RecoveryKey.recover(escrow: keystore.escrow, code: newCode),
                         "new code recovers")
        XCTAssertThrowsError(try RecoveryKey.recover(escrow: keystore.escrow, code: oldCode),
                             "old code no longer recovers")
        let viewed = await EncryptionProvisioner.viewRecoveryCode(saveFolder: saveFolder, session: session)
        XCTAssertEqual(viewed, newCode, "view now returns the new code")
    }

    // MARK: - Key rotation / revocation

    func testRotateKeyRekeysForwardAndRevokesOldKeyAndCode() async throws {
        let pkg = saveFolder.appendingPathComponent("a.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("{\"version\":4}".utf8).write(to: pkg.appendingPathComponent("manifest.json"))
        let oldCode = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }
        XCTAssertTrue(SealPackageCrypter.isLocked(pkg))
        let oldGenID = try XCTUnwrap(session.activeGeneration).id

        let rotated = await EncryptionProvisioner.rotateKey(
            saveFolder: saveFolder, session: session, identityStore: store)
        let summary = try XCTUnwrap(rotated)
        XCTAssertNotEqual(summary.newRecoveryCode, oldCode)
        XCTAssertEqual(summary.rekeyedPackages, 1)
        XCTAssertEqual(summary.failedPackages, 0)

        // New active generation; old retired in the keyring; old keychain item gone.
        let newGen = try XCTUnwrap(session.activeGeneration)
        XCTAssertNotEqual(newGen.id, oldGenID)
        let keyring = try XCTUnwrap(Keyring.read(fromFolder: capsuleFolder))
        XCTAssertEqual(keyring.activeGenerationID, newGen.id)
        XCTAssertNotNil(keyring.record(for: oldGenID)?.retiredAt, "old generation retired")
        XCTAssertFalse(store.hasStoredIdentity(for: keyring.record(for: oldGenID)!.generation),
                       "old generation's keychain item deleted")

        // The package is re-keyed to the NEW identity (data preserved, still locked).
        XCTAssertTrue(SealPackageCrypter.isLocked(pkg))
        let newIdentity = try XCTUnwrap(session.unlockedIdentityForDrain())
        let header = try JSONDecoder().decode(
            LockHeader.self, from: try XCTUnwrap(sealEntryData("lock.json", at: pkg)))
        XCTAssertEqual(header.capsule.generationID, newGen.id)
        XCTAssertNoThrow(try SealPackageCrypter.unwrapCEK(header, identity: newIdentity))

        // Old recovery code is dead; the new one recovers.
        let ks = try XCTUnwrap(Keystore.read(fromFolder: saveFolder))
        XCTAssertThrowsError(try RecoveryKey.recover(escrow: ks.escrow, code: oldCode))
        XCTAssertNoThrow(try RecoveryKey.recover(escrow: ks.escrow, code: summary.newRecoveryCode))
    }

    func testRotateKeyReturnsNilWhenLockedOut() async throws {
        _ = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }
        // Lose the key entirely: lock + wipe the store → can't re-wrap.
        session.lock()
        try store.delete()
        let rotated = await EncryptionProvisioner.rotateKey(
            saveFolder: saveFolder, session: session, identityStore: store)
        XCTAssertNil(rotated, "rotation needs the current key; nil when locked out")
    }
}
