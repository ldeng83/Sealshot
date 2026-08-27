import XCTest
import CryptoKit
@testable import Sealshot

@MainActor
final class SealPackageIOEncryptionTests: XCTestCase {
    let identity = IdentityKey.generate()
    lazy var gen = KeyGeneration.make(publicKey: identity.publicKey)
    var crypto: SealPackageCryptoContext {
        SealPackageCryptoContext(publicKey: identity.publicKey, generation: gen, identity: identity)
    }
    var writeOnly: SealPackageCryptoContext {
        SealPackageCryptoContext(publicKey: identity.publicKey, generation: gen, identity: nil)
    }
    var plain: SealPackageCryptoContext {
        SealPackageCryptoContext(publicKey: nil, identity: nil)
    }
    var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("io-enc-\(UUID().uuidString).seal")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: url) }

    private func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testPlainContextWritesPlaintextV4() throws {
        let img = makeImage()
        let cek = try writeSealPackage(to: url, source: img, composite: img,
                                       annotations: [], crop: nil, crypto: plain)
        XCTAssertNil(cek)
        XCTAssertFalse(SealPackageCrypter.isLocked(url))
        let manifestRaw = try XCTUnwrap(sealEntryData("manifest.json", at: url))
        XCTAssertNoThrow(try SealManifest.decodeJSON(from: manifestRaw))
    }

    func testLockedWriteSealsEverythingAndReadsBack() throws {
        let img = makeImage()
        let cek = try writeSealPackage(to: url, source: img, composite: img,
                                       annotations: [], crop: nil, crypto: writeOnly)
        XCTAssertNotNil(cek)
        XCTAssertTrue(SealPackageCrypter.isLocked(url))
        for entry in ["manifest.json", "source.png", "composite.png", "annotations.json"] {
            let raw = try XCTUnwrap(sealEntryData(entry, at: url))
            XCTAssertTrue(SealedBlob.isSealed(raw), "\(entry) must be sealed")
        }
        let contents = try readSealPackage(at: url, crypto: crypto)
        XCTAssertEqual(contents.manifest.version, SealManifest.currentVersion)
    }

    func testReadLockedWithoutIdentityThrowsPackageLocked() throws {
        let img = makeImage()
        _ = try writeSealPackage(to: url, source: img, composite: img,
                                 annotations: [], crop: nil, crypto: writeOnly)
        XCTAssertThrowsError(try readSealPackage(at: url, crypto: writeOnly)) { error in
            guard case SealPackageIOError.packageLocked = error else {
                return XCTFail("expected .packageLocked, got \(error)")
            }
        }
    }

    func testOverwriteReusesCEKAndPreservesCreated() throws {
        let img = makeImage()
        let cek1 = try writeSealPackage(to: url, source: img, composite: img,
                                        annotations: [], crop: nil, crypto: writeOnly)
        let created = try readSealPackage(at: url, crypto: crypto).manifest.createdISO8601
        let cek2 = try writeSealPackage(to: url, source: img, composite: img,
                                        annotations: [], crop: nil, crypto: crypto)
        XCTAssertEqual(cek1!.withUnsafeBytes { Data($0) }, cek2!.withUnsafeBytes { Data($0) })
        let after = try readSealPackage(at: url, crypto: crypto)
        XCTAssertEqual(after.manifest.createdISO8601, created)
    }

    func testOverwriteLockedWithoutIdentityThrows() throws {
        let img = makeImage()
        _ = try writeSealPackage(to: url, source: img, composite: img,
                                 annotations: [], crop: nil, crypto: writeOnly)
        XCTAssertThrowsError(try writeSealPackage(to: url, source: img, composite: img,
                                                  annotations: [], crop: nil, crypto: writeOnly)) { error in
            guard case SealPackageIOError.packageLocked = error else {
                return XCTFail("expected .packageLocked, got \(error)")
            }
        }
    }

    func testPlainPackageReadsUnchangedUnderCryptoContext() throws {
        let img = makeImage()
        _ = try writeSealPackage(to: url, source: img, composite: img,
                                 annotations: [], crop: nil, crypto: plain)
        // Locked-capable reader must still read legacy/plaintext packages.
        XCTAssertNoThrow(try readSealPackage(at: url, crypto: crypto))
    }

    // MARK: - Task 6: graceful degradation

    /// captureDate(of:) on a locked .seal must not throw — it falls back to
    /// mtime (or the provided fallback) because manifest.json bytes are sealed
    /// and will fail JSON decode, triggering the try? fallback path.
    func testCaptureDateOfLockedPackageFallsBackToMtime() throws {
        let img = makeImage()
        _ = try writeSealPackage(to: url, source: img, composite: img,
                                 annotations: [], crop: nil, crypto: writeOnly)
        XCTAssertTrue(SealPackageCrypter.isLocked(url))
        let fallback = Date(timeIntervalSince1970: 42)
        // Must not throw — returns fallback (or file creation date) instead of crashing.
        let date = captureDate(of: url, fallback: fallback)
        XCTAssertNotNil(date)
    }

    /// listCaptures on a folder containing a locked .seal must not crash or
    /// throw — the locked package appears in results with its mtime as the date.
    func testListCapturesWithLockedPackageDoesNotCrash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("listcap-locked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let seal = dir.appendingPathComponent("locked.seal")
        let img = makeImage()
        _ = try writeSealPackage(to: seal, source: img, composite: img,
                                 annotations: [], crop: nil, crypto: writeOnly)
        XCTAssertTrue(SealPackageCrypter.isLocked(seal))

        // Must not crash or throw. Returns one entry with a non-nil date.
        let results = listCaptures(in: dir)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.0.lastPathComponent, "locked.seal")
    }

    /// captureThumbnailImage on a locked .seal package WITHOUT an identity (the
    /// session is locked) must return nil — not crash. ImageIO can't decode the
    /// AES-GCM ciphertext, so this is the placeholder path.
    func testCaptureThumbnailImageForLockedPackageWithoutIdentityReturnsNil() throws {
        let img = makeImage()
        _ = try writeSealPackage(to: url, source: img, composite: img,
                                 annotations: [], crop: nil, crypto: writeOnly)
        XCTAssertTrue(SealPackageCrypter.isLocked(url))

        let thumbnail = captureThumbnailImage(for: url, crypto: writeOnly)
        XCTAssertNil(thumbnail, "locked package without identity must yield a nil thumbnail")
    }

    /// With the session unlocked (identity present), captureThumbnailImage must
    /// decrypt the sealed thumbnail/composite and return a real image.
    func testCaptureThumbnailImageForLockedPackageWithIdentityDecrypts() throws {
        let img = makeImage()
        _ = try writeSealPackage(to: url, source: img, composite: img,
                                 annotations: [], crop: nil, crypto: writeOnly)
        XCTAssertTrue(SealPackageCrypter.isLocked(url))

        let thumbnail = captureThumbnailImage(for: url, crypto: crypto)
        XCTAssertNotNil(thumbnail, "unlocked session must decrypt and return a thumbnail")
    }

    /// A wrong identity (can't unwrap the CEK) must fail closed → nil, not crash.
    func testCaptureThumbnailImageForLockedPackageWithWrongIdentityReturnsNil() throws {
        let img = makeImage()
        _ = try writeSealPackage(to: url, source: img, composite: img,
                                 annotations: [], crop: nil, crypto: writeOnly)
        let wrong = SealPackageCryptoContext(publicKey: nil, identity: IdentityKey.generate())
        XCTAssertNil(captureThumbnailImage(for: url, crypto: wrong))
    }
}
