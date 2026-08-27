import XCTest
@testable import Sealshot

@MainActor
final class SealPackageIOTests: XCTestCase {

    private func makeImage(width: Int = 100, height: Int = 80) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealPackageIOTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_roundTrip_emptyAnnotations() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.seal")

        let source = makeImage()
        try writeSealPackage(
            to: url,
            source: source,
            composite: source,
            annotations: [],
            crop: nil,
            crypto: SealPackageCryptoContext(publicKey: nil, identity: nil)
        )

        let contents = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(contents.annotations.count, 0)
        XCTAssertNil(contents.crop)
        XCTAssertEqual(contents.source.width, source.width)
        XCTAssertEqual(contents.composite.width, source.width)
        XCTAssertEqual(contents.manifest.version, SealManifest.currentVersion)
        XCTAssertEqual(contents.manifest.sourceSize.width, source.width)
        XCTAssertEqual(contents.manifest.sourceSize.height, source.height)
    }

    func test_roundTrip_fullAnnotationsAndCrop() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("annotated.seal")

        let source = makeImage(width: 200, height: 150)
        let annotations: [Annotation] = [
            Annotation(
                geometry: .arrow(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 90)),
                style: Style(strokeColor: SerializableColor(.red), strokeWidth: 4)
            ),
            Annotation(
                geometry: .rectangle(rect: CGRect(x: 20, y: 30, width: 40, height: 50)),
                style: Style(strokeColor: SerializableColor(.blue), strokeWidth: 3)
            ),
        ]
        let crop = CGRect(x: 5, y: 5, width: 100, height: 75)

        try writeSealPackage(
            to: url,
            source: source,
            composite: source,    // composite content doesn't matter for this test
            annotations: annotations,
            crop: crop,
            crypto: SealPackageCryptoContext(publicKey: nil, identity: nil)
        )

        let contents = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(contents.annotations, annotations)
        XCTAssertEqual(contents.crop, crop)
    }

    func test_rewriteExistingPackage_overrides_inPlace() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rewrite.seal")
        let source = makeImage()

        try writeSealPackage(to: url, source: source, composite: source, annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let firstRead = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(firstRead.annotations.count, 0)

        let updated: [Annotation] = [
            Annotation(
                geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
                style: Style(strokeColor: SerializableColor(.green), strokeWidth: 2)
            )
        ]
        try writeSealPackage(to: url, source: source, composite: source, annotations: updated, crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let secondRead = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(secondRead.annotations, updated)
    }
}
