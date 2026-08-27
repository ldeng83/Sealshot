import XCTest
@testable import Sealshot

@MainActor
final class EncryptionIntegrationTests: XCTestCase {
    func testFullFlow_provisionEncryptLockUnlockRecover() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Provision: identity + recovery code + keystore.
        let identityStore = InMemoryIdentityStore()
        let identity = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: identity.publicKey)
        try identityStore.save(identity, for: gen)
        let code = RecoveryKey.generateCode()
        try Keystore.create(identity: identity, recoveryCode: code, generation: gen).write(toFolder: dir)

        let defaults = UserDefaults(suiteName: "e2e-\(UUID().uuidString)")!
        let session = EncryptionSession(identityStore: identityStore,
                                        capsuleFolder: dir, defaults: defaults)
        session.isEnabled = true
        try session.provision(publicKey: identity.publicKey, generation: gen)
        let unlockOk = try await session.unlock()
        XCTAssertTrue(unlockOk)

        // Encrypt the undo timeline through the session key, lock, verify unreadable.
        let timeline = GlobalUndoTimelineStore(
            fileURL: dir.appendingPathComponent("undo-timeline.json"),
            keyProvider: { MainActor.assumeIsolated { try? session.contentKey(for: .history) } })
        timeline.save(GlobalUndoStore.Persisted(undoStack: [], redoStack: []))
        session.lock()
        XCTAssertNil(timeline.load())

        // "New machine": Keychain empty, recover identity from keystore + code.
        try identityStore.delete()
        let keystore = try XCTUnwrap(Keystore.read(fromFolder: dir))
        let recovered = try RecoveryKey.recover(escrow: keystore.escrow, code: code)
        try identityStore.save(recovered)
        let recoverOk = try await session.unlock()
        XCTAssertTrue(recoverOk)
        XCTAssertNotNil(timeline.load())
    }
}
