import XCTest
@testable import Sealshot

@MainActor
final class SceneManifestTests: XCTestCase {

    private func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private func tempSeal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneManifest-\(UUID().uuidString).seal")
    }

    func testSceneLayers_roundTripThroughManifestJSON() throws {
        let layer = SceneLayer(assetID: "a1", app: "Finder", title: "Desktop",
                               bundleID: "com.apple.finder",
                               originalFrame: CGRect(x: 10, y: 20, width: 100, height: 80), z: 3)
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "t", modifiedISO8601: "t",
            sourceSize: SealManifest.Size(width: 8, height: 8),
            sourceApp: nil, captureKind: .liveCapture, sceneLayers: [layer])
        let data = try manifest.encodeJSON()
        let decoded = try SealManifest.decodeJSON(from: data)
        XCTAssertEqual(decoded.captureKind, .liveCapture)
        XCTAssertEqual(decoded.sceneLayers, [layer])
    }

    func testSceneLayers_persistThroughWriteRead() throws {
        let url = tempSeal(); defer { try? FileManager.default.removeItem(at: url) }
        let img = makeImage()
        let layer = SceneLayer(assetID: "a1", app: "Finder", title: "Desktop",
                               bundleID: "com.apple.finder",
                               originalFrame: CGRect(x: 1, y: 2, width: 3, height: 4), z: 0)
        try writeSealPackage(to: url, source: img, composite: img,
                             annotations: [], crop: nil,
                             captureKind: .liveCapture, sceneLayers: [layer],
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let contents = try readSealPackage(
            at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(contents.manifest.captureKind, .liveCapture)
        XCTAssertEqual(contents.manifest.sceneLayers, [layer])
    }

    /// REGRESSION (field bug, 2026-07-20): the metadata pipeline (auto-title/
    /// tags, seconds after every capture) rebuilds the manifest field-by-field
    /// and silently dropped sceneLayers — a fresh Live Capture lost its scene
    /// identity before the user ever touched it. Every SealMetadataStore
    /// rewrite must carry sceneLayers forward.
    func testMetadataApply_preservesSceneLayers() throws {
        let url = tempSeal(); defer { try? FileManager.default.removeItem(at: url) }
        let img = makeImage()
        let layer = SceneLayer(assetID: "a1", app: "Finder", title: "Desktop",
                               bundleID: "com.apple.finder",
                               originalFrame: CGRect(x: 1, y: 2, width: 3, height: 4), z: 0)
        try writeSealPackage(to: url, source: img, composite: img,
                             annotations: [], crop: nil,
                             captureKind: .liveCapture, sceneLayers: [layer],
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        // The exact rewrite the auto-title/tags pipeline performs post-capture.
        try SealMetadataStore.apply(
            metadata: CaptureMetadata(generatedTitle: "My Scene", userTitle: nil,
                                      tags: ["desk"], category: .other,
                                      confidence: 1.0, generatorVersion: 1),
            sourceApp: nil, to: url)

        let contents = try readSealPackage(
            at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(contents.manifest.metadata?.generatedTitle, "My Scene")
        XCTAssertEqual(contents.manifest.sceneLayers, [layer],
                       "metadata rewrites must never strip scene layers")

        // OCR backfill is a second, independent rewrite path — same contract.
        try SealMetadataStore.applyOCRText("hello", to: url)
        let again = try readSealPackage(
            at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(again.manifest.sceneLayers, [layer])
    }
}
