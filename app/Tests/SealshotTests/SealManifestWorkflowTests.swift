import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class SealManifestWorkflowTests: XCTestCase {

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
    func testLegacyManifestDecodesNotFavoriteNew() throws {
        let json = """
        {"version":6,"createdISO8601":"t","modifiedISO8601":"t",
         "sourceSize":{"width":4,"height":4},"sourceApp":null}
        """.data(using: .utf8)!
        let m = try SealManifest.decodeJSON(from: json)
        XCTAssertNil(m.isFavorite)
        XCTAssertNil(m.status)
        XCTAssertFalse(CaptureWorkflow.isFavorite(m))      // nil → false
        XCTAssertEqual(CaptureWorkflow.status(m), .new)    // nil → .new
    }
    func testRoundTripsWorkflow() throws {
        let m = SealManifest(
            version: SealManifest.currentVersion, createdISO8601: "t", modifiedISO8601: "t",
            sourceSize: .init(width: 4, height: 4), sourceApp: nil,
            isFavorite: true, status: .archived)
        let back = try SealManifest.decodeJSON(from: m.encodeJSON())
        XCTAssertEqual(back.isFavorite, true)
        XCTAssertEqual(back.status, .archived)
        XCTAssertEqual(SealManifest.currentVersion, 14)
    }

    func testDecode_v11ManifestWithoutEnhanceParams_yieldsNil() throws {
        // Old packages (pre-v12) have no `enhanceParams` key; must decode cleanly.
        let json = """
        {"version":11,"createdISO8601":"2026-06-01T00:00:00Z",
         "modifiedISO8601":"2026-06-01T00:00:00Z",
         "sourceSize":{"width":100,"height":50},"sourceApp":null}
        """.data(using: .utf8)!
        let m = try SealManifest.decodeJSON(from: json)
        XCTAssertNil(m.enhanceParams)
    }

    func testSetWorkflow_preservesProvenanceAndMetadata() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        // Stamp provenance and a pageDomain via apply
        try SealMetadataStore.apply(metadata: nil, sourceApp: nil,
                                    captureKind: .screenshot, captureMode: .area,
                                    pageDomain: "example.com", to: url)
        // Now set workflow
        try SealMetadataStore.setWorkflow(isFavorite: true, status: .reviewed, to: url)
        let read = try readSealPackage(at: url,
                                       crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(read.manifest.isFavorite, true)
        XCTAssertEqual(read.manifest.status, .reviewed)
        // Provenance must survive
        XCTAssertEqual(read.manifest.pageDomain, "example.com")
        XCTAssertEqual(read.manifest.captureKind, .screenshot)
        // Partial update: only isFavorite, status stays
        try SealMetadataStore.setWorkflow(isFavorite: false, to: url)
        let read2 = try readSealPackage(at: url,
                                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(read2.manifest.isFavorite, false)
        XCTAssertEqual(read2.manifest.status, .reviewed) // unchanged
    }

    /// A re-save (editor ⌘S / autosave overwrites the package in place via
    /// `writeSealPackage`) must NOT drop workflow or provenance. Regression for
    /// the whole-branch finding: `writeSealPackage` is a fifth manifest writer
    /// that rebuilt the manifest from `existingManifest` but dropped these
    /// carry-forward fields, silently wiping a favorited/archived flag (and the
    /// SP-B provenance) on the next annotation edit.
    func testReSavePreservesWorkflowAndProvenance() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let crypto = SealPackageCryptoContext(publicKey: nil, identity: nil)
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                             crypto: crypto)
        try SealMetadataStore.apply(metadata: nil, sourceApp: nil,
                                    captureKind: .screenshot, captureMode: .window,
                                    pageDomain: "github.com", to: url)
        try SealMetadataStore.setWorkflow(isFavorite: true, status: .archived, to: url)

        // Re-save the package in place (as an annotation edit / autosave would).
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                             crypto: crypto)

        let read = try readSealPackage(at: url, crypto: crypto)
        XCTAssertEqual(read.manifest.isFavorite, true)          // workflow survives re-save
        XCTAssertEqual(read.manifest.status, .archived)
        XCTAssertEqual(read.manifest.captureKind, .screenshot)  // provenance survives re-save
        XCTAssertEqual(read.manifest.captureMode, .window)
        XCTAssertEqual(read.manifest.pageDomain, "github.com")
    }
}
