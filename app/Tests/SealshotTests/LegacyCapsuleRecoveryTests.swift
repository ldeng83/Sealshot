import XCTest
import CryptoKit
@testable import Sealshot

/// A capsule left behind by an earlier encryption era must not be able to stop
/// encryption being turned on again.
///
/// It could. Turning Enhanced Security on wrote a fresh keyring, flipped
/// `isEnabled` true, and then asked for the library-index content key — which
/// hit a v1 capsule from a previous enable (encryption had since been turned
/// off, which left the capsule and the sealed index behind). v1 has no
/// `generationID`, so `KeyCapsule` fails to decode, and `contentKey` let that
/// error escape. `EncryptionProvisioner.enable` aborted there: after the flag
/// was on, but BEFORE `purgePlaintextIndex()` and before `SealMigrator`. The
/// library reported itself encrypted while every package stayed plaintext and
/// the plaintext index — OCR text, titles, tags — stayed on disk.
///
/// `KeyCapsule` already documents the intent: a legacy capsule "FAILS to decode
/// — callers treat that as 'no usable capsule' (wipe-ok, no backward compat)".
/// These tests hold `contentKey` to it.
@MainActor
final class LegacyCapsuleRecoveryTests: XCTestCase {
    var dir: URL!
    var store: InMemoryIdentityStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-capsule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = InMemoryIdentityStore()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeSession() -> EncryptionSession {
        let defaults = UserDefaults(suiteName: "legacy-capsule-\(UUID().uuidString)")!
        let s = EncryptionSession(identityStore: store, capsuleFolder: dir, defaults: defaults)
        s.isEnabled = true
        return s
    }

    /// Exactly the shape found on disk: version 1, no `generationID`.
    private func writeLegacyV1Capsule(for store: EncryptionSession.Store) throws {
        let legacy: [String: Any] = [
            "version": 1,
            "encapsulated": Data(repeating: 0xAB, count: 32).base64EncodedString(),
            "ciphertext": Data(repeating: 0xCD, count: 48).base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: dir.appendingPathComponent("\(store.rawValue).capsule"))
    }

    func test_legacyCapsule_doesNotThrow_andVendsAKey() async throws {
        let identity = IdentityKey.generate()
        try store.save(identity)
        try writeLegacyV1Capsule(for: .libraryIndex)

        let s = makeSession()
        try s.provision(publicKey: identity.publicKey,
                        generation: KeyGeneration.make(publicKey: identity.publicKey))
        _ = try await s.unlock()

        // Before the fix this threw DecodingError.keyNotFound(generationID),
        // which aborted enabling encryption entirely.
        let key = try s.contentKey(for: .libraryIndex)
        XCTAssertNotNil(key, "a legacy capsule must be replaced, not fatal")
    }

    func test_legacyCapsule_isRewrittenAtTheCurrentGeneration() async throws {
        let identity = IdentityKey.generate()
        try store.save(identity)
        try writeLegacyV1Capsule(for: .libraryIndex)

        let s = makeSession()
        let generation = KeyGeneration.make(publicKey: identity.publicKey)
        try s.provision(publicKey: identity.publicKey, generation: generation)
        _ = try await s.unlock()
        _ = try s.contentKey(for: .libraryIndex)

        // Left as v1 it would fail again on the next launch.
        let data = try Data(contentsOf: dir.appendingPathComponent("library-index.capsule"))
        let capsule = try JSONDecoder().decode(KeyCapsule.self, from: data)
        XCTAssertEqual(capsule.generationID, generation.id)
    }

    func test_replacementKeyIsStableAcrossCalls() async throws {
        let identity = IdentityKey.generate()
        try store.save(identity)
        try writeLegacyV1Capsule(for: .libraryIndex)

        let s = makeSession()
        try s.provision(publicKey: identity.publicKey,
                        generation: KeyGeneration.make(publicKey: identity.publicKey))
        _ = try await s.unlock()

        let first = try XCTUnwrap(try s.contentKey(for: .libraryIndex)).withUnsafeBytes { Data($0) }
        let second = try XCTUnwrap(try s.contentKey(for: .libraryIndex)).withUnsafeBytes { Data($0) }
        XCTAssertEqual(first, second, "a key that changed per call would seal data it cannot reopen")
    }

    /// The deliberate behaviour that must SURVIVE the fix: a well-formed v2
    /// capsule from a different generation is a diverged library, not junk, and
    /// still reports itself as such rather than silently discarding the key.
    func test_v2CapsuleFromAnotherGeneration_stillThrowsGenerationMismatch() async throws {
        let identity = IdentityKey.generate()
        try store.save(identity)

        // Seal a capsule under one generation...
        let older = KeyGeneration.make(publicKey: identity.publicKey)
        let strayKey = SymmetricKey(size: .bits256)
        let stray = try identity.publicKey.wrap(contentKey: strayKey, generation: older)
        try JSONEncoder().encode(stray)
            .write(to: dir.appendingPathComponent("library-index.capsule"))

        // ...then run the session on a different one.
        let s = makeSession()
        try s.provision(publicKey: identity.publicKey,
                        generation: KeyGeneration.make(publicKey: identity.publicKey))
        _ = try await s.unlock()

        XCTAssertThrowsError(try s.contentKey(for: .libraryIndex)) { error in
            guard case EncryptionError.generationMismatch = error else {
                return XCTFail("expected generationMismatch, got \(error)")
            }
        }
    }
}
