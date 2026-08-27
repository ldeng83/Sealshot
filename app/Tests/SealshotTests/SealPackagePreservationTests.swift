import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class SealPackagePreservationTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-\(UUID().uuidString).seal")
    }

    private func solidImage(_ w: Int, _ h: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    func testRewrite_preservesMetadata() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let img = solidImage(4, 4)

        // First write (fresh capture): no metadata yet.
        try writeSealPackage(to: url, source: img, composite: img, annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        // Simulate the coordinator stamping metadata into manifest.json directly.
        let meta = CaptureMetadata(generatedTitle: "Stamped", userTitle: nil, tags: ["t"],
                                   category: .error, confidence: 0.6, generatorVersion: 1)
        var manifest = try SealManifest.decodeJSON(
            from: try XCTUnwrap(sealEntryData("manifest.json", at: url)))
        manifest = SealManifest(version: 3, createdISO8601: manifest.createdISO8601,
                                modifiedISO8601: manifest.modifiedISO8601,
                                sourceSize: manifest.sourceSize, sourceApp: "Safari",
                                showingEnhanced: manifest.showingEnhanced, metadata: meta)
        try SealContainer.rewritingManifest(manifest.encodeJSON(), in: url)

        // Editor re-save (annotation edit) goes through writeSealPackage again.
        try writeSealPackage(to: url, source: img, composite: img, annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        let read = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(read.manifest.metadata, meta)
        XCTAssertEqual(read.manifest.sourceApp, "Safari")
        XCTAssertEqual(read.manifest.version, SealManifest.currentVersion)
    }
}
