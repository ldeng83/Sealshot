import XCTest
import AppKit
@testable import Sealshot

final class AnnotatedPNGIOTests: XCTestCase {

    private func makeCGImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotatedPNGIOTests-\(UUID()).png")
    }

    func testWriteAndRead_roundTripsAnnotationsAndCrop() throws {
        let composite = makeCGImage(width: 64, height: 48)
        let source    = makeCGImage(width: 100, height: 80)
        let arrow = Annotation(
            geometry: .arrow(start: CGPoint(x: 5, y: 5), end: CGPoint(x: 50, y: 40)),
            style: Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1), strokeWidth: 3)
        )
        let crop = CGRect(x: 10, y: 10, width: 64, height: 48)
        let metadata = try encodeAnnotations([arrow], crop: crop)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try writeAnnotatedPNG(composite: composite, source: source, metadataJSON: metadata, to: url)
        let pkg = try readAnnotatedPNG(url: url)

        XCTAssertEqual(pkg.composite.width, 64)
        XCTAssertEqual(pkg.composite.height, 48)
        XCTAssertNotNil(pkg.source)
        XCTAssertEqual(pkg.source?.width, 100)
        XCTAssertEqual(pkg.source?.height, 80)
        XCTAssertEqual(pkg.annotations, [arrow])
        XCTAssertEqual(pkg.crop, crop)
    }

    func testRead_rawPngWithoutMetadata_returnsNilSourceAndEmptyAnnotations() throws {
        let composite = makeCGImage(width: 32, height: 32)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Write a plain PNG without our metadata — use CGImageDestination directly.
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, composite, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let pkg = try readAnnotatedPNG(url: url)
        XCTAssertNotNil(pkg.composite)
        XCTAssertNil(pkg.source)
        XCTAssertEqual(pkg.annotations, [])
        XCTAssertNil(pkg.crop)
    }

    func testWriteAndRead_emptyAnnotations() throws {
        let composite = makeCGImage(width: 32, height: 32)
        let source    = makeCGImage(width: 32, height: 32)
        let metadata = try encodeAnnotations([], crop: nil)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try writeAnnotatedPNG(composite: composite, source: source, metadataJSON: metadata, to: url)
        let pkg = try readAnnotatedPNG(url: url)

        XCTAssertEqual(pkg.annotations, [])
        XCTAssertNil(pkg.crop)
        XCTAssertNotNil(pkg.source)
    }

    func testRead_missingFile_throws() {
        let url = URL(fileURLWithPath: "/tmp/this-does-not-exist-\(UUID()).png")
        XCTAssertThrowsError(try readAnnotatedPNG(url: url))
    }
}
