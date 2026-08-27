import XCTest
import CryptoKit
@testable import Sealshot

@MainActor
final class EncryptionPhase2IntegrationTests: XCTestCase {
    func testCaptureWhileLockedThenUnlockDrainEditAndDisable() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2e2e-\(UUID().uuidString)", isDirectory: true)
        let saveFolder = base.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = InMemoryIdentityStore()
        let session = EncryptionSession(
            identityStore: store, capsuleFolder: base.appendingPathComponent("keys"),
            defaults: UserDefaults(suiteName: "p2-\(UUID().uuidString)")!)

        // Enable (empty library).
        let code = try await EncryptionProvisioner.enable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }
        XCTAssertFalse(code.isEmpty)
        let loaded = try await store.load()
        let identity = try XCTUnwrap(loaded)

        // "Locked capture": write a package with public key only.
        session.lock()
        let writeOnly = SealPackageCryptoContext(publicKey: session.publicKey, generation: session.activeGeneration, identity: nil)
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let pkg = saveFolder.appendingPathComponent("locked-cap.seal")
        let cek = try writeSealPackage(to: pkg, source: img, composite: img,
                                       annotations: [], crop: nil, crypto: writeOnly)
        XCTAssertNotNil(cek)
        XCTAssertTrue(SealPackageCrypter.isLocked(pkg))

        // Metadata patch + pending enqueue while locked (the capture pipeline path).
        let queueFolder = base.appendingPathComponent("queue")
        let queue = PendingIndexQueue(folder: queueFolder)
        let coordinator = MetadataCoordinator(
            ocr: { _ in [] }, pendingQueue: queue,
            publicKeyProvider: { session.publicKey },
            generationProvider: { session.activeGeneration })
        await coordinator.generate(for: pkg, sourceApp: "TestApp", windowTitle: "Big Secret Doc",
                                   captureDate: Date(), packageKey: cek, source: img)
        XCTAssertEqual(queue.count, 1)

        // Index store with everything injected; locked reconcile must not clobber.
        let dbURL = base.appendingPathComponent("idx.sqlite")
        let indexStore = LibraryIndexStore(
            databaseURL: dbURL,
            keyProvider: { try? session.contentKey(for: .libraryIndex) },
            identityProvider: { session.unlockedIdentityForDrain() },
            pendingQueue: queue)

        // Unlock → items() drains the queue → title searchable.
        _ = try await session.unlock()
        let items = await indexStore.items(
            section: .allFiles, saveFolder: saveFolder, search: "", now: Date())
        XCTAssertEqual(items.count, 1)
        // Reconcile again (mtime unchanged): row survives.
        let again = await indexStore.items(
            section: .allFiles, saveFolder: saveFolder, search: "", now: Date())
        XCTAssertEqual(again.count, 1)

        // Editor-style read + save round-trip stays locked with same CEK.
        let full = SealPackageCryptoContext(publicKey: session.publicKey,
                                            generation: session.activeGeneration,
                                            identity: session.unlockedIdentityForDrain())
        let contents = try readSealPackage(at: pkg, crypto: full)
        let cek2 = try writeSealPackage(to: pkg, source: contents.source,
                                        composite: contents.composite,
                                        annotations: contents.annotations,
                                        crop: contents.crop, crypto: full)
        XCTAssertEqual(cek!.withUnsafeBytes { Data($0) }, cek2!.withUnsafeBytes { Data($0) })

        // Disable: everything decrypts, reads work plain.
        await EncryptionProvisioner.disable(
            saveFolder: saveFolder, session: session, identityStore: store) { _, _ in }
        XCTAssertFalse(SealPackageCrypter.isLocked(pkg))
        let plainCtx = SealPackageCryptoContext(publicKey: nil, identity: nil)
        XCTAssertNoThrow(try readSealPackage(at: pkg, crypto: plainCtx))
        _ = identity // silence if unused after adaptations
    }
}
