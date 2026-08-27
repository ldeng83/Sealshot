import XCTest
@testable import Sealshot

@MainActor
final class ImageAssetPackageIOTests: XCTestCase {

    private func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func tempSeal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAssetIO-\(UUID().uuidString).seal")
    }

    func testAssets_roundTripPlaintext() throws {
        let url = tempSeal(); defer { try? FileManager.default.removeItem(at: url) }
        let img = makeImage()
        let assetPNG = try CaptureOutputWriter.encodePNG(img)
        let annotation = Annotation(
            geometry: .image(rect: CGRect(x: 0, y: 0, width: 8, height: 8),
                             assetID: "asset-one"),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0))

        try writeSealPackage(to: url, source: img, composite: img,
                             annotations: [annotation], crop: nil,
                             assets: ["asset-one": assetPNG],
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        XCTAssertNotNil(sealEntryData("asset-asset-one.png", at: url),
                        "the asset is carried as a container entry")
        let contents = try readSealPackage(
            at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(contents.imageAssets.keys.sorted(), ["asset-one"])
        XCTAssertEqual(contents.annotations, [annotation])
    }

    func testAssets_absent_readsEmptyDictionary() throws {
        let url = tempSeal(); defer { try? FileManager.default.removeItem(at: url) }
        let img = makeImage()
        try writeSealPackage(to: url, source: img, composite: img,
                             annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let contents = try readSealPackage(
            at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertTrue(contents.imageAssets.isEmpty)
    }

    // MARK: - Compositing smoke test

    // Encrypted round-trip: IdentityKey.generate() is headless (no keychain),
    // so this test runs without any keychain access.
    func testAssets_roundTripEncrypted() throws {
        let url = tempSeal(); defer { try? FileManager.default.removeItem(at: url) }
        let identity = IdentityKey.generate()
        let crypto = SealPackageCryptoContext(publicKey: identity.publicKey, generation: .make(publicKey: identity.publicKey), identity: identity)

        let img = makeImage()
        let assetPNG = try CaptureOutputWriter.encodePNG(img)
        let annotation = Annotation(
            geometry: .image(rect: CGRect(x: 0, y: 0, width: 8, height: 8),
                             assetID: "asset-one"),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0))

        try writeSealPackage(to: url, source: img, composite: img,
                             annotations: [annotation], crop: nil,
                             assets: ["asset-one": assetPNG],
                             crypto: crypto)

        XCTAssertTrue(SealPackageCrypter.isLocked(url),
                      "package must be locked when a publicKey is supplied")
        let contents = try readSealPackage(at: url, crypto: crypto)
        XCTAssertEqual(contents.imageAssets.keys.sorted(), ["asset-one"])
        XCTAssertEqual(contents.annotations, [annotation])
    }
}
