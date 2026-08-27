import XCTest
@testable import Sealshot

final class NewCanvasFactoryTests: XCTestCase {

    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("NewCanvasFactoryTests-\(UUID().uuidString)"))
    }

    func test_blank_hasRequestedSize_andDefaults() throws {
        let img = try XCTUnwrap(NewCanvasFactory.blank(size: CGSize(width: 64, height: 40)))
        XCTAssertEqual(img.width, 64)
        XCTAssertEqual(img.height, 40)

        let defaulted = try XCTUnwrap(NewCanvasFactory.blank())
        XCTAssertEqual(defaulted.width, 800)
        XCTAssertEqual(defaulted.height, 500)
    }

    func test_blank_isTransparent() throws {
        let img = try XCTUnwrap(NewCanvasFactory.blank(size: CGSize(width: 4, height: 4)))
        // Sample the center pixel — a blank canvas is now fully transparent
        // (the editor shows a checkerboard; the persisted backgroundFill stays
        // nil until the user picks a fill).
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -2, y: -2, width: 4, height: 4))
        let pixel = ctx.data!.bindMemory(to: UInt8.self, capacity: 4)
        XCTAssertEqual(pixel[3], 0, "transparent, not opaque white")
    }

    func test_clipboard_roundTripsImage() throws {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        let source = try XCTUnwrap(NewCanvasFactory.blank(size: CGSize(width: 10, height: 6)))
        let nsImage = NSImage(cgImage: source, size: NSSize(width: 10, height: 6))
        pb.clearContents()
        pb.writeObjects([nsImage])

        XCTAssertTrue(NewCanvasFactory.clipboardHasImage(pb))
        let read = try XCTUnwrap(NewCanvasFactory.fromClipboard(pb))
        XCTAssertEqual(read.width, 10)
        XCTAssertEqual(read.height, 6)
    }

    func test_clipboard_empty_returnsNil() {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("not an image", forType: .string)

        XCTAssertFalse(NewCanvasFactory.clipboardHasImage(pb))
        XCTAssertNil(NewCanvasFactory.fromClipboard(pb))
    }

    // MARK: Blank-canvas recognition

    func test_isBlankCanvas_trueForAFreshCanvas() throws {
        let blank = try XCTUnwrap(NewCanvasFactory.blank(size: CGSize(width: 40, height: 24)))
        XCTAssertTrue(NewCanvasFactory.isBlankCanvas(blank))
    }

    /// A capture is opaque, so it must never be mistaken for a drawing
    /// surface — that is what keeps a pasted photo from growing a screenshot.
    func test_isBlankCanvas_falseForAnOpaqueImage() throws {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let opaque = try XCTUnwrap(ctx.makeImage())
        XCTAssertFalse(NewCanvasFactory.isBlankCanvas(opaque))
    }

    /// One drawn pixel is enough: the surface has content, so a paste must
    /// not resize it out from under that content.
    func test_isBlankCanvas_falseWhenASinglePixelIsPainted() throws {
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: 16, height: 16))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 15, y: 15, width: 1, height: 1))   // last pixel scanned
        let painted = try XCTUnwrap(ctx.makeImage())
        XCTAssertFalse(NewCanvasFactory.isBlankCanvas(painted))
    }
}
