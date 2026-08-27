import XCTest
@testable import Sealshot

/// A store that saves but whose `load()` always fails — standing in for the
/// keychain when Touch ID is denied or the item is unreachable. Recovery must
/// not depend on `load()` (the recovery code is the proof of ownership).
private final class DenyLoadIdentityStore: IdentityStore {
    private let backing = InMemoryIdentityStore()
    func save(_ identity: IdentityKey) throws { try backing.save(identity) }
    func load() async throws -> IdentityKey? { nil }
    /// Unreachable keychain: promptless reads fail for the same reason.
    func loadWithoutUserPresence() throws -> IdentityKey? { nil }
    func hasStoredIdentity() -> Bool { backing.hasStoredIdentity() }
    func delete() throws { try backing.delete() }
}

@MainActor
final class RecoveryEntryModelTests: XCTestCase {
    var saveFolder: URL!
    var capsuleFolder: URL!
    var store: InMemoryIdentityStore!
    var session: EncryptionSession!
    var realCode: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
        saveFolder = base.appendingPathComponent("captures")
        capsuleFolder = base.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        store = InMemoryIdentityStore()
        session = EncryptionSession(identityStore: store, capsuleFolder: capsuleFolder,
                                    defaults: UserDefaults(suiteName: "rec-\(UUID().uuidString)")!)
        session.isEnabled = true
        // Provision a keystore in the save folder (as enable() would), then
        // wipe the Keychain identity to simulate a fresh Mac.
        let identity = IdentityKey.generate()
        realCode = RecoveryKey.generateCode()
        try Keystore.create(identity: identity, recoveryCode: realCode,
                            generation: .make(publicKey: identity.publicKey)).write(toFolder: saveFolder)
        // (Keychain empty: store has nothing — fresh-Mac state.)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saveFolder.deletingLastPathComponent())
    }

    func model() -> RecoveryEntryModel {
        RecoveryEntryModel(saveFolder: saveFolder, session: session, identityStore: store)
    }

    func testCorrectCodeRecoversAndUnlocks() async throws {
        let m = model()
        let ok = await m.recover(code: realCode)
        XCTAssertTrue(ok)
        XCTAssertTrue(session.isUnlocked)
        let storeLoaded = try await store.load()
        XCTAssertNotNil(storeLoaded)          // identity persisted for next launch
        XCTAssertNotNil(session.publicKey)          // re-provisioned
    }

    func testWrongCodeFailsWithoutUnlocking() async throws {
        let m = model()
        let ok = await m.recover(code: RecoveryKey.generateCode())
        XCTAssertFalse(ok)
        XCTAssertFalse(session.isUnlocked)
        XCTAssertNotNil(m.errorMessage)
    }

    func testMissingKeystoreFails() async throws {
        try FileManager.default.removeItem(at: saveFolder.appendingPathComponent(Keystore.filename))
        let m = model()
        let ok = await m.recover(code: realCode)
        XCTAssertFalse(ok)
        XCTAssertNotNil(m.errorMessage)
    }

    func testNormalizedCodeAccepted() async throws {
        let m = model()
        let ok = await m.recover(code: realCode.lowercased().replacingOccurrences(of: "-", with: " "))
        XCTAssertTrue(ok)
    }

    func testRecoverDoesNotRePromptViaKeychainLoad() async throws {
        // Recovery adopts the just-recovered key directly; it must NOT route
        // through load() (the Touch ID prompt). A store whose load() always
        // fails would block the old unlock() path but not adoption.
        let denyStore = DenyLoadIdentityStore()
        let s = EncryptionSession(identityStore: denyStore, capsuleFolder: capsuleFolder,
                                  defaults: UserDefaults(suiteName: "rec-deny-\(UUID().uuidString)")!)
        s.isEnabled = true
        let m = RecoveryEntryModel(saveFolder: saveFolder, session: s, identityStore: denyStore)
        let ok = await m.recover(code: realCode)
        XCTAssertTrue(ok, "recovery must succeed without depending on load()")
        XCTAssertTrue(s.isUnlocked)
    }
}
