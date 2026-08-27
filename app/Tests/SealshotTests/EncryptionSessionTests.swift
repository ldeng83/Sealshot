import XCTest
import CryptoKit
@testable import Sealshot

@MainActor
final class EncryptionSessionTests: XCTestCase {
    var dir: URL!
    var store: InMemoryIdentityStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = InMemoryIdentityStore()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func makeSession(enabled: Bool = true) -> EncryptionSession {
        let defaults = UserDefaults(suiteName: "session-tests-\(UUID().uuidString)")!
        let s = EncryptionSession(identityStore: store, capsuleFolder: dir, defaults: defaults)
        s.isEnabled = enabled
        return s
    }

    func testDisabledSessionVendsNoKeys() throws {
        let s = makeSession(enabled: false)
        XCTAssertNil(try s.contentKey(for: .history))
        XCTAssertFalse(s.isUnlocked)
    }

    func testEnableProvisionThenUnlockVendsStableKey() async throws {
        let s = makeSession()
        let identity = IdentityKey.generate()
        try store.save(identity)
        try s.provision(publicKey: identity.publicKey, generation: KeyGeneration.make(publicKey: identity.publicKey))
        let ok = try await s.unlock()
        XCTAssertTrue(ok)
        let k1 = try XCTUnwrap(try s.contentKey(for: .history))
        let k2 = try XCTUnwrap(try s.contentKey(for: .history))
        XCTAssertEqual(k1.withUnsafeBytes { Data($0) }, k2.withUnsafeBytes { Data($0) })
        let idx = try XCTUnwrap(try s.contentKey(for: .libraryIndex))
        XCTAssertNotEqual(k1.withUnsafeBytes { Data($0) }, idx.withUnsafeBytes { Data($0) })
    }

    func testKeysSurviveRelaunch() async throws {
        let identity = IdentityKey.generate()
        try store.save(identity)
        let s1 = makeSession()
        try s1.provision(publicKey: identity.publicKey, generation: KeyGeneration.make(publicKey: identity.publicKey))
        _ = try await s1.unlock()
        let k1 = try XCTUnwrap(try s1.contentKey(for: .history)).withUnsafeBytes { Data($0) }

        let s2 = makeSession() // fresh session, same capsule folder + store
        _ = try await s2.unlock()
        let k2 = try XCTUnwrap(try s2.contentKey(for: .history)).withUnsafeBytes { Data($0) }
        XCTAssertEqual(k1, k2)
    }

    func testLockClearsKeys() async throws {
        let identity = IdentityKey.generate()
        try store.save(identity)
        let s = makeSession()
        try s.provision(publicKey: identity.publicKey, generation: KeyGeneration.make(publicKey: identity.publicKey))
        _ = try await s.unlock()
        XCTAssertNotNil(try s.contentKey(for: .history))
        s.lock()
        XCTAssertFalse(s.isUnlocked)
        XCTAssertNil(try s.contentKey(for: .history))
    }

    func testUnlockWithoutIdentityFails() async throws {
        let s = makeSession()
        let ok = try await s.unlock()
        XCTAssertFalse(ok)
    }

    func testRecordingsKey_isDistinct_stable_andNilWhenDisabled() async throws {
        let identity = IdentityKey.generate()
        try store.save(identity)
        let s = makeSession()
        try s.provision(publicKey: identity.publicKey, generation: KeyGeneration.make(publicKey: identity.publicKey))
        _ = try await s.unlock()

        let rec1 = try XCTUnwrap(try s.contentKey(for: .recordings)).withUnsafeBytes { Data($0) }
        let rec2 = try XCTUnwrap(try s.contentKey(for: .recordings)).withUnsafeBytes { Data($0) }
        let hist = try XCTUnwrap(try s.contentKey(for: .history)).withUnsafeBytes { Data($0) }
        XCTAssertEqual(rec1, rec2, "recordings key is stable within a session")
        XCTAssertNotEqual(rec1, hist, "recordings key is distinct from the history key")

        XCTAssertNil(try makeSession(enabled: false).contentKey(for: .recordings))
    }

    func testIdentityAvailable_falseWhenNoKey_trueOnceStored() async throws {
        let s = makeSession()
        // Enabled but no identity on this Mac → the dead-end the lock screen
        // must detect and steer to recovery instead of a silent Unlock no-op.
        XCTAssertFalse(s.identityAvailable)
        try store.save(IdentityKey.generate())
        XCTAssertTrue(s.identityAvailable)
    }

    func testIdentityAvailable_trueWhileUnlockedEvenIfStoreCleared() async throws {
        try store.save(IdentityKey.generate())
        let s = makeSession()
        _ = try await s.unlock()
        try store.delete()
        // Key is held in memory for this session, so it's still "available".
        XCTAssertTrue(s.identityAvailable)
    }

    func testCorruptExistingCapsuleThrowsInsteadOfRegenerating() async throws {
        let identity = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: identity.publicKey)
        try store.save(identity, for: gen)
        let s = makeSession()
        try s.provision(publicKey: identity.publicKey, generation: gen)
        _ = try await s.unlock()
        _ = try s.contentKey(for: .history) // creates the capsule
        s.lock()

        // Corrupt the capsule on disk.
        let capsuleURL = dir.appendingPathComponent("history.capsule")
        try Data("garbage".utf8).write(to: capsuleURL)

        let s2 = makeSession()
        _ = try await s2.unlock()
        XCTAssertThrowsError(try s2.contentKey(for: .history))
        // And the corrupt file must NOT have been overwritten with a new capsule.
        XCTAssertEqual(try Data(contentsOf: capsuleURL), Data("garbage".utf8))
    }

    func testRekeyStoreCapsulesRewrapsToNewIdentity() async throws {
        let oldIdentity = IdentityKey.generate()
        let oldGen = KeyGeneration.make(publicKey: oldIdentity.publicKey)
        try store.save(oldIdentity, for: oldGen)
        let s = makeSession()
        try s.provision(publicKey: oldIdentity.publicKey, generation: oldGen)
        _ = try await s.unlock()
        let key = try XCTUnwrap(try s.contentKey(for: .history)).withUnsafeBytes { Data($0) } // creates capsule

        let newIdentity = IdentityKey.generate()
        let newGen = KeyGeneration.make(publicKey: newIdentity.publicKey)
        try s.rekeyStoreCapsules(to: newIdentity.publicKey, generation: newGen, using: oldIdentity)

        let capsule = try JSONDecoder().decode(
            KeyCapsule.self, from: try Data(contentsOf: dir.appendingPathComponent("history.capsule")))
        XCTAssertEqual(capsule.generationID, newGen.id)
        XCTAssertEqual(try newIdentity.unwrap(capsule: capsule).withUnsafeBytes { Data($0) }, key,
                       "content key unchanged, just re-wrapped")
        XCTAssertThrowsError(try oldIdentity.unwrap(capsule: capsule),
                             "old identity can't unwrap the re-keyed capsule")
    }

    func testForeignGenerationCapsuleThrowsTypedMismatch() async throws {
        // Generation A writes a capsule.
        let idA = IdentityKey.generate()
        let genA = KeyGeneration.make(publicKey: idA.publicKey)
        try store.save(idA, for: genA)
        let s = makeSession()
        try s.provision(publicKey: idA.publicKey, generation: genA)
        _ = try await s.unlock()
        _ = try s.contentKey(for: .history)   // history.capsule stamped genA
        s.lock()

        // A different generation B becomes active over the same capsule folder
        // (the divergence the old model crashed on). The stale capsule must now
        // surface a TYPED, catchable mismatch — not an opaque HPKE failure.
        let idB = IdentityKey.generate()
        let genB = KeyGeneration.make(publicKey: idB.publicKey)
        try store.save(idB, for: genB)
        let s2 = makeSession()
        try s2.provision(publicKey: idB.publicKey, generation: genB)
        _ = try await s2.unlock()
        XCTAssertThrowsError(try s2.contentKey(for: .history)) { error in
            guard case EncryptionError.generationMismatch(let expected, let found) = error else {
                return XCTFail("expected generationMismatch, got \(error)")
            }
            XCTAssertEqual(expected, genB.id)
            XCTAssertEqual(found, genA.id)
        }
    }
}
