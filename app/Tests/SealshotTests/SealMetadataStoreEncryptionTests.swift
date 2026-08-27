import XCTest
import CryptoKit
@testable import Sealshot

@MainActor
final class SealMetadataStoreEncryptionTests: XCTestCase {
    let identity = IdentityKey.generate()
    var url: URL!
    var cek: SymmetricKey!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-enc-\(UUID().uuidString).seal", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Hand-build a minimal locked package: sealed manifest + lock.json.
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "2026-06-11T00:00:00Z", modifiedISO8601: "2026-06-11T00:00:00Z",
            sourceSize: .init(width: 4, height: 4), sourceApp: nil,
            showingEnhanced: false, metadata: nil, ocrText: nil)
        let sealed = try SealPackageCrypter.sealEntries(
            ["manifest.json": try manifest.encodeJSON()], publicKey: identity.publicKey, generation: KeyGeneration.make(publicKey: identity.publicKey))
        cek = sealed.cek
        for (name, data) in sealed.entries {
            try data.write(to: url.appendingPathComponent(name))
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: url) }

    private var sampleMetadata: CaptureMetadata {
        // Adapt to CaptureMetadata's real initializer.
        CaptureMetadata(generatedTitle: "Locked Test", userTitle: nil, tags: ["x"],
                        category: .other, confidence: 0.9, generatorVersion: 1)
    }

    func testReadLockedManifestWithPackageKey() throws {
        let manifest = try SealMetadataStore.readManifest(at: url, packageKey: cek)
        XCTAssertEqual(manifest.createdISO8601, "2026-06-11T00:00:00Z")
    }

    func testReadLockedWithoutKeyOrIdentityThrows() {
        XCTAssertThrowsError(try SealMetadataStore.readManifest(at: url))
    }

    func testCorruptLockHeaderIsNotMaskedAsLocked() throws {
        // Identity available but lock.json is garbage → corruption, not
        // .packageLocked (which would suppress recovery/retry UI).
        try Data("garbage".utf8).write(to: url.appendingPathComponent(LockHeader.filename))
        XCTAssertThrowsError(try SealMetadataStore.resolveCEK(
            at: url, packageKey: nil, identity: identity)) { error in
            guard case SealMetadataStore.CryptoError.lockHeaderCorrupt = error else {
                return XCTFail("expected .lockHeaderCorrupt, got \(error)")
            }
        }
    }

    func testApplyPatchesAndStaysSealed() throws {
        try SealMetadataStore.apply(metadata: sampleMetadata, sourceApp: "TestApp",
                                    ocrText: "SECRET TEXT", to: url, packageKey: cek)
        let raw = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        XCTAssertTrue(SealedBlob.isSealed(raw))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("SECRET TEXT"))
        let back = try SealMetadataStore.readManifest(at: url, packageKey: cek)
        XCTAssertEqual(back.ocrText, "SECRET TEXT")
        XCTAssertEqual(back.metadata?.generatedTitle, "Locked Test")
    }

    func testPlainPackageUnaffected() throws {
        let plainURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-plain-\(UUID().uuidString).seal", isDirectory: true)
        try FileManager.default.createDirectory(at: plainURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plainURL) }
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "2026-06-11T00:00:00Z", modifiedISO8601: "2026-06-11T00:00:00Z",
            sourceSize: .init(width: 4, height: 4), sourceApp: nil,
            showingEnhanced: false, metadata: nil, ocrText: nil)
        try manifest.encodeJSON().write(to: plainURL.appendingPathComponent("manifest.json"))
        try SealMetadataStore.apply(metadata: sampleMetadata, sourceApp: nil,
                                    ocrText: "plain", to: plainURL)
        let raw = try Data(contentsOf: plainURL.appendingPathComponent("manifest.json"))
        XCTAssertFalse(SealedBlob.isSealed(raw))
        XCTAssertEqual(try SealMetadataStore.readManifest(at: plainURL).ocrText, "plain")
    }
}
