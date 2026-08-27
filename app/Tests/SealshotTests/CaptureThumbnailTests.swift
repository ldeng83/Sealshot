import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class CaptureThumbnailTests: XCTestCase {

    /// Plaintext context: no keys → behaves like a pre-encryption (v4) load.
    private let noCrypto = SealPackageCryptoContext(publicKey: nil, identity: nil)

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testPng_loadsDirectly() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shot.png")
        try pngData().write(to: url)
        XCTAssertNotNil(captureThumbnailImage(for: url, crypto: noCrypto))
    }

    func testSeal_loadsComposite() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let seal = dir.appendingPathComponent("shot.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: seal, withIntermediateDirectories: true)
        try pngData().write(to: seal.appendingPathComponent("composite.png"))
        XCTAssertNotNil(captureThumbnailImage(for: seal, crypto: noCrypto))
    }

    func testSeal_missingComposite_returnsNil() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let seal = dir.appendingPathComponent("empty.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: seal, withIntermediateDirectories: true)
        XCTAssertNil(captureThumbnailImage(for: seal, crypto: noCrypto))
    }

    // MARK: downsampledImage

    private func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    func test_downsampledImage_capsLongEdge_preservesAspect() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("big.png")
        try writePNG(makeImage(width: 2000, height: 1000), to: png)

        let image = try XCTUnwrap(downsampledImage(at: png, maxPixel: 720))
        XCTAssertEqual(image.size.width, 720, accuracy: 1)
        XCTAssertEqual(image.size.height, 360, accuracy: 1)
    }

    func test_downsampledImage_smallImageKeepsSize() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("small.png")
        try writePNG(makeImage(width: 100, height: 80), to: png)

        let image = try XCTUnwrap(downsampledImage(at: png, maxPixel: 720))
        XCTAssertEqual(image.size.width, 100, accuracy: 1)
        XCTAssertEqual(image.size.height, 80, accuracy: 1)
    }

    func test_downsampledImage_missingFile_returnsNil() {
        XCTAssertNil(downsampledImage(
            at: URL(fileURLWithPath: "/nonexistent/x.png"), maxPixel: 720))
    }

    // MARK: save-time thumbnail entry

    func test_writeSealPackage_writesDownsampledThumbnail() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let seal = dir.appendingPathComponent("big.seal")
        let composite = makeImage(width: 1600, height: 1200)
        try writeSealPackage(to: seal, source: composite, composite: composite,
                             annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        let thumbPNG = try XCTUnwrap(sealEntryData("thumbnail.png", at: seal))
        let thumb = try XCTUnwrap(downsampledImage(from: thumbPNG, maxPixel: 10_000))
        XCTAssertEqual(thumb.size.width, 720, accuracy: 1)
        XCTAssertEqual(thumb.size.height, 540, accuracy: 1)
    }

    func test_writeSealPackage_smallComposite_skipsThumbnail() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let seal = dir.appendingPathComponent("small.seal")
        let composite = makeImage(width: 100, height: 80)
        try writeSealPackage(to: seal, source: composite, composite: composite,
                             annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        // composite.png is already thumbnail-sized; a duplicate entry would
        // just waste bytes — the thumbnail reader falls back to it.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: seal.appendingPathComponent("thumbnail.png").path))
    }
}
