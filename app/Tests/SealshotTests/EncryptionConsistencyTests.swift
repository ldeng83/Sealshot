import XCTest
import CryptoKit
@testable import Sealshot

final class EncryptionConsistencyTests: XCTestCase {
    var saveFolder: URL!
    var capsuleFolder: URL!
    var store: InMemoryIdentityStore!
    var defaults: UserDefaults!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("consist-\(UUID().uuidString)", isDirectory: true)
        saveFolder = base.appendingPathComponent("captures")
        capsuleFolder = base.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: capsuleFolder, withIntermediateDirectories: true)
        store = InMemoryIdentityStore()
        defaults = UserDefaults(suiteName: "consist-\(UUID().uuidString)")!
        defaults.set(true, forKey: EncryptionSession.enabledKey)  // enabled unless a test says otherwise
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saveFolder.deletingLastPathComponent())
    }

    // MARK: helpers

    private func newIdentityAndGeneration() -> (IdentityKey, KeyGeneration) {
        let id = IdentityKey.generate()
        return (id, KeyGeneration.make(publicKey: id.publicKey))
    }

    private func record(_ identity: IdentityKey, _ gen: KeyGeneration) -> GenerationRecord {
        GenerationRecord(generation: gen, publicKeyRaw: identity.publicKey.rawRepresentation, retiredAt: nil)
    }

    private func writeCapsule(store name: String, publicKey: IdentityPublicKey,
                              generation: KeyGeneration) throws {
        let capsule = try publicKey.wrap(contentKey: SymmetricKey(size: .bits256), generation: generation)
        try JSONEncoder().encode(capsule)
            .write(to: capsuleFolder.appendingPathComponent("\(name).capsule"))
    }

    private func check() -> ConsistencyStatus {
        EncryptionConsistency.check(saveFolder: saveFolder, capsuleFolder: capsuleFolder,
                                    identityStore: store, defaults: defaults)
    }

    // MARK: - off

    func testOffWhenFlagDisabled() {
        defaults.set(false, forKey: EncryptionSession.enabledKey)
        XCTAssertEqual(check(), .off)
    }

    func testOffWhenEnabledButNothingProvisioned() {
        // Flag on, but no keyring and no capsules → a clean (just-enabled-empty) state.
        XCTAssertEqual(check(), .off)
    }

    // MARK: - consistent

    func testConsistentWhenIdentityPresentAndCapsuleMatches() throws {
        let (id, gen) = newIdentityAndGeneration()
        try Keyring.initial(record(id, gen)).write(toFolder: capsuleFolder)
        try writeCapsule(store: "history", publicKey: id.publicKey, generation: gen)
        try store.save(id, for: gen)
        XCTAssertEqual(check(), .consistent(gen))
    }

    // MARK: - recoverable

    func testRecoverableWhenIdentityMissingButEscrowPresent() throws {
        let (id, gen) = newIdentityAndGeneration()
        try Keyring.initial(record(id, gen)).write(toFolder: capsuleFolder)
        // No identity in the store, but the keystore escrows this generation.
        try Keystore.create(identity: id, recoveryCode: RecoveryKey.generateCode(), generation: gen)
            .write(toFolder: saveFolder)
        XCTAssertEqual(check(), .recoverable(gen))
    }

    // MARK: - diverged

    func testDivergedNoKeyringWhenCapsuleExistsWithoutKeyring() throws {
        let (id, gen) = newIdentityAndGeneration()
        try writeCapsule(store: "history", publicKey: id.publicKey, generation: gen)
        // No keyring written.
        XCTAssertEqual(check(), .diverged(.noKeyring))
    }

    func testDivergedOrphanCapsuleWhenStampUnknownToKeyring() throws {
        let (idA, genA) = newIdentityAndGeneration()
        let (idB, genB) = newIdentityAndGeneration()
        try Keyring.initial(record(idA, genA)).write(toFolder: capsuleFolder)
        // Capsule stamped with a generation the keyring never recorded.
        try writeCapsule(store: "history", publicKey: idB.publicKey, generation: genB)
        try store.save(idA, for: genA)
        XCTAssertEqual(check(), .diverged(.orphanCapsule(store: "history", stampedGeneration: genB.id)))
    }

    func testDivergedNoIdentityNoEscrow() throws {
        let (id, gen) = newIdentityAndGeneration()
        try Keyring.initial(record(id, gen)).write(toFolder: capsuleFolder)
        // No identity in store, no keystore on disk.
        XCTAssertEqual(check(), .diverged(.noIdentityNoEscrow(gen)))
    }

    // MARK: - does not scan packages

    func testConsistentEvenWithManyPackagesPresent() throws {
        // Drop a bunch of .seal dirs in the save folder; the check must classify
        // purely from keyring + capsule headers, never enumerating these.
        for i in 0..<50 {
            let pkg = saveFolder.appendingPathComponent("p\(i).seal", isDirectory: true)
            try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: pkg.appendingPathComponent("lock.json"))
        }
        let (id, gen) = newIdentityAndGeneration()
        try Keyring.initial(record(id, gen)).write(toFolder: capsuleFolder)
        try store.save(id, for: gen)
        XCTAssertEqual(check(), .consistent(gen))
    }
}
