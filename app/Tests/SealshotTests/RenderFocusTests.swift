import XCTest
import AppKit
import CoreGraphics
@testable import Sealshot

final class RenderFocusTests: XCTestCase {
    private func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testFocusCropsOutputSize() {
        let out = render(image: image(100, 80), annotations: [], crop: nil,
                         focus: CGRect(x: 10, y: 20, width: 40, height: 30))
        XCTAssertEqual(out.size, CGSize(width: 40, height: 30))
    }

    func testNilFocusUnchanged() {
        let out = render(image: image(100, 80), annotations: [], crop: nil, focus: nil)
        XCTAssertEqual(out.size, CGSize(width: 100, height: 80))
    }

    func testFocusCropsTopRegionNotFlipped() {
        // Build a 100×100 source: image-space TOP half red, BOTTOM half blue.
        // CGContext is y-up, so fill y∈[50,100) (CG) to paint the visual top.
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))   // bottom (CG y 0..50) = blue
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))   // top (CG y 50..100) = red
        ctx.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
        let src = ctx.makeImage()!

        // Focus the TOP half in image (top-left) coords.
        let out = render(image: src, annotations: [], crop: nil,
                         focus: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(out.size, CGSize(width: 100, height: 50))

        let cg = out.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let rep = NSBitmapImageRep(cgImage: cg)                          // top-left origin
        let c = rep.colorAt(x: 50, y: 10)!.usingColorSpace(.deviceRGB)!  // near top of output
        XCTAssertGreaterThan(c.redComponent, 0.8, "focus crop should grab the red TOP half, not the blue bottom (Y-flip bug)")
        XCTAssertLessThan(c.blueComponent, 0.2)
    }
}

/// Drag-out export of a focused capture: crops to the focus area (Export
/// parity) instead of baking the preview brackets into the file.
@MainActor
final class FocusExportCropTests: XCTestCase {
    private func flat(_ w: Int, _ h: Int) -> NSImage {
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSColor.black.setFill(); NSRect(x: 10, y: 10, width: 5, height: 5).fill()
        img.unlockFocus()
        return img
    }

    func test_imageCroppedToFocus_cropsToNormalizedRect() throws {
        // lockFocus renders at the host's backing scale — assert proportions
        // against the source's actual pixels, not its point size.
        let src = flat(200, 100)
        let srcCG = try XCTUnwrap(src.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let cropped = FocusPreviewIndicator.imageCroppedToFocus(
            src, normalized: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6))
        let cg = try XCTUnwrap(cropped.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, srcCG.width / 2)                       // 0.5 of width
        XCTAssertEqual(cg.height, Int(Double(srcCG.height) * 0.6))     // 0.6 of height
    }

    func test_imageCroppedToFocus_degenerateRectReturnsOriginal() throws {
        let src = flat(200, 100)
        let srcCG = try XCTUnwrap(src.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let out = FocusPreviewIndicator.imageCroppedToFocus(
            src, normalized: CGRect(x: 1.5, y: 1.5, width: 0.1, height: 0.1))
        let cg = try XCTUnwrap(out.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, srcCG.width)
        XCTAssertEqual(cg.height, srcCG.height)
    }
}
