import XCTest
import CoreImage
import CoreGraphics
@testable import Sealshot

final class VisionTaggerTests: XCTestCase {

    private let tagger = VisionTagger()

    // MARK: fixture helpers

    /// Render a CoreImage output into a white-backed CGImage of the given size.
    private func cgImage(from ci: CIImage, size: CGSize) throws -> CGImage {
        let ctx = CIContext()
        let scaleX = size.width / ci.extent.width
        let scaleY = size.height / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return try XCTUnwrap(ctx.createCGImage(scaled, from: CGRect(origin: .zero, size: size)),
                             "CIContext failed to render \(size) image")
    }

    private func qrImage() throws -> CGImage {
        let f = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        f.setValue("https://seal-shot.com".data(using: .ascii), forKey: "inputMessage")
        return try cgImage(from: try XCTUnwrap(f.outputImage), size: CGSize(width: 600, height: 600))
    }

    private func barcodeImage() throws -> CGImage {
        let f = try XCTUnwrap(CIFilter(name: "CICode128BarcodeGenerator"))
        f.setValue("SEALSHOT123".data(using: .ascii), forKey: "inputMessage")
        return try cgImage(from: try XCTUnwrap(f.outputImage), size: CGSize(width: 600, height: 200))
    }

    /// Loads a fixture image from the repo's `testing/test images` folder.
    /// Test target sets `SEALSHOT_FIXTURES` to that absolute path (scheme env),
    /// falling back to a relative path from the source file.
    private func fixture(_ name: String) throws -> CGImage {
        let base = ProcessInfo.processInfo.environment["SEALSHOT_FIXTURES"]
            ?? (URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("testing/test images").path)
        let url = URL(fileURLWithPath: base).appendingPathComponent(name)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil),
                                "Missing or unreadable fixture at \(url.path)")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil),
                             "Could not decode fixture at \(url.path)")
    }

    // MARK: structural detectors

    func testDetectsQRCode() throws {
        let t = tagger.tags(for: try qrImage())
        XCTAssertTrue(t.structural.contains("qr-code"))
    }

    func testDetectsBarcode() throws {
        let t = tagger.tags(for: try barcodeImage())
        XCTAssertTrue(t.structural.contains("barcode"))
    }

    func testQRImageHasNoFaceTag() throws {
        let t = tagger.tags(for: try qrImage())
        XCTAssertFalse(t.structural.contains("contains-faces"))
    }

    func testDetectsFaceInPassportPhoto() throws {
        // passport2.jpg contains a portrait photo.
        let t = tagger.tags(for: try fixture("passport2.jpg"))
        XCTAssertTrue(t.structural.contains("contains-faces"))
    }
}
