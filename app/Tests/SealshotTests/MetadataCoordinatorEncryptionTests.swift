import XCTest
import CryptoKit
@testable import Sealshot

@MainActor
final class MetadataCoordinatorEncryptionTests: XCTestCase {
    func testLockedPackagePatchEnqueuesPendingEntry() async throws {
        let identity = IdentityKey.generate()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mc-\(UUID().uuidString)", isDirectory: true)
        let queueDir = dir.appendingPathComponent("queue")
        let seal = dir.appendingPathComponent("cap.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: seal, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Minimal locked package (manifest only — coordinator gets source in-memory).
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "2026-06-11T00:00:00Z", modifiedISO8601: "2026-06-11T00:00:00Z",
            sourceSize: .init(width: 4, height: 4), sourceApp: nil,
            showingEnhanced: false, metadata: nil, ocrText: nil)
        let sealed = try SealPackageCrypter.sealEntries(
            ["manifest.json": try manifest.encodeJSON()], publicKey: identity.publicKey, generation: KeyGeneration.make(publicKey: identity.publicKey))
        for (name, data) in sealed.entries {
            try data.write(to: seal.appendingPathComponent(name))
        }

        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!

        let queue = PendingIndexQueue(folder: queueDir)
        let gen = KeyGeneration.make(publicKey: identity.publicKey)
        let coordinator = MetadataCoordinator(
            ocr: { _ in [] },
            pendingQueue: queue,
            publicKeyProvider: { identity.publicKey },
            generationProvider: { gen })
        await coordinator.generate(for: seal, sourceApp: "TestApp", windowTitle: "Hello World",
                                   captureDate: Date(), packageKey: sealed.cek, source: img)

        XCTAssertEqual(queue.count, 1)
        let drained = queue.drain(identity: identity)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?.row.path, seal.standardizedFileURL.path)
        // Manifest got patched and stayed sealed.
        let raw = try Data(contentsOf: seal.appendingPathComponent("manifest.json"))
        XCTAssertTrue(SealedBlob.isSealed(raw))
    }
}
