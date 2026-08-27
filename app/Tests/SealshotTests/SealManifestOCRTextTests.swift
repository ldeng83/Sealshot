import XCTest
import CoreGraphics
@testable import Sealshot

/// Manifest v4: `ocrText` — full OCR text of source.png stored in the package.
/// nil = never OCR-indexed (pre-v4 package); "" = OCR ran, no text found.
@MainActor
final class SealManifestOCRTextTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-\(UUID().uuidString).seal")
    }
    private func img() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private func meta(_ title: String) -> CaptureMetadata {
        CaptureMetadata(generatedTitle: title, userTitle: nil, tags: ["t"],
                        category: .other, confidence: 0.6, generatorVersion: 1)
    }

    // MARK: Codable

    func testCurrentVersion_is14() {
        // Bumped to 12 when enhanceParams was added to the manifest.
        XCTAssertEqual(SealManifest.currentVersion, 14)
    }

    func testDecode_v3ManifestWithoutOCRText_yieldsNil() throws {
        let json = """
        {"version":3,"createdISO8601":"2026-06-08T10:00:00Z",
         "modifiedISO8601":"2026-06-08T10:00:00Z",
         "sourceSize":{"width":100,"height":50}}
        """.data(using: .utf8)!
        let m = try SealManifest.decodeJSON(from: json)
        XCTAssertNil(m.ocrText)
    }

    func testRoundTrip_withOCRText() throws {
        let m = SealManifest(version: 4, createdISO8601: "c", modifiedISO8601: "mod",
                             sourceSize: .init(width: 1, height: 2),
                             sourceApp: nil, ocrText: "Login\nPassword")
        let back = try SealManifest.decodeJSON(from: m.encodeJSON())
        XCTAssertEqual(back.ocrText, "Login\nPassword")
    }

    // MARK: Rewriters preserve ocrText

    func testWriteSealPackage_preservesExistingOCRText() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        try SealMetadataStore.applyOCRText("hello world", to: url)
        // Editor save rewrites the whole package — text must survive.
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil)).manifest.ocrText, "hello world")
    }

    func testApplyMetadata_withOCRText_stampsBoth() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        try SealMetadataStore.apply(metadata: meta("T"), sourceApp: "Safari", ocrText: "Sign in", to: url)
        let m = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil)).manifest
        XCTAssertEqual(m.metadata, meta("T"))
        XCTAssertEqual(m.ocrText, "Sign in")
    }

    func testApplyMetadata_withoutOCRText_preservesOld() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        try SealMetadataStore.applyOCRText("keep me", to: url)
        try SealMetadataStore.apply(metadata: meta("T"), sourceApp: nil, to: url)
        XCTAssertEqual(try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil)).manifest.ocrText, "keep me")
    }

    func testUpdate_preservesOCRText() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        try SealMetadataStore.apply(metadata: meta("Auto"), sourceApp: nil, ocrText: "txt", to: url)
        try SealMetadataStore.update(at: url) { $0.userTitle = "Edited" }
        let m = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil)).manifest
        XCTAssertEqual(m.ocrText, "txt")
        XCTAssertEqual(m.metadata?.userTitle, "Edited")
    }

    // MARK: applyOCRText

    func testApplyOCRText_neverTouchesMetadata_andUpgradesVersion() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        try SealMetadataStore.apply(metadata: meta("User stuff"), sourceApp: "Xcode", to: url)
        try SealMetadataStore.applyOCRText("backfilled", to: url)
        let m = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil)).manifest
        XCTAssertEqual(m.ocrText, "backfilled")
        XCTAssertEqual(m.metadata, meta("User stuff"))   // backfill must not clobber
        XCTAssertEqual(m.sourceApp, "Xcode")
        XCTAssertEqual(m.version, SealManifest.currentVersion)
    }

    func testApplyOCRText_missingPackage_throws() {
        XCTAssertThrowsError(try SealMetadataStore.applyOCRText("x", to: tempURL()))
    }
}
