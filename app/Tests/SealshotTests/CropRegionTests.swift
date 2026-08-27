import XCTest
import AppKit
import CoreGraphics
@testable import Sealshot

final class CropRegionTests: XCTestCase {

    // MARK: - Helpers

    private func solidImage(_ w: Int, _ h: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Read the alpha component at image-space (x, y) where y=0 is the TOP row.
    /// Converts to `colorAt(x:y:)` coordinates (y=0 at BOTTOM) before reading.
    private func alpha(of rep: NSBitmapImageRep, imageX x: Int, imageY iy: Int) -> CGFloat {
        let h = rep.pixelsHigh
        // colorAt(x:y:) uses y=0 at bottom; image-space y=0 is at the top.
        let cy = h - iy - 1
        return rep.colorAt(x: x, y: cy)?.alphaComponent ?? -1
    }

    // MARK: - Render transparency test

    func test_cutAnnotation_producesTransparentPixels() {
        let base = solidImage(40, 40)
        let cut = Annotation(
            geometry: .cut(rect: CGRect(x: 10, y: 10, width: 20, height: 20)),
            style: Style(strokeColor: SerializableColor(.red), strokeWidth: 1)
        )
        let out = render(image: base, annotations: [cut], crop: nil)

        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            XCTFail("failed to get bitmap rep from rendered NSImage")
            return
        }

        // Center of cut rect in image-space (20, 20) → must be transparent.
        let centerAlpha = alpha(of: rep, imageX: 20, imageY: 20)
        XCTAssertLessThan(centerAlpha, 0.1,
            "center of cut rect should be transparent (alpha=0), got \(centerAlpha)")

        // Corner of image (2, 2) outside the cut rect → must remain opaque.
        let cornerAlpha = alpha(of: rep, imageX: 2, imageY: 2)
        XCTAssertGreaterThan(cornerAlpha, 0.9,
            "corner outside cut rect should be opaque (alpha=1), got \(cornerAlpha)")
    }

    // MARK: - Hit-test: edge-only (no fill)

    func test_cutAnnotation_hitTestIsEdgeOnly() {
        let cut = Annotation(
            geometry: .cut(rect: CGRect(x: 10, y: 10, width: 20, height: 20)),
            style: Style(strokeColor: SerializableColor(.red), strokeWidth: 1)
        )
        let tolerance: CGFloat = 3

        // Interior well inside the cut rect should NOT register a hit.
        let interiorHit = hitTestAnnotations([cut], at: CGPoint(x: 20, y: 20), tolerance: tolerance)
        XCTAssertNil(interiorHit, "interior of cut region should not be hittable")

        // Point right on the left edge should register a hit.
        let edgeHit = hitTestAnnotations([cut], at: CGPoint(x: 10, y: 20), tolerance: tolerance)
        XCTAssertNotNil(edgeHit, "edge of cut region should be hittable")
    }
}

// MARK: - Task 3: CropRegion tests

extension CropRegionTests {
    func test_compositedRegion_returnsRectSizedImage() {
        let base = solidImage(40, 40)
        let region = compositedRegion(image: base, annotations: [], assets: [:],
                                      rect: CGRect(x: 5, y: 5, width: 20, height: 10))
        XCTAssertNotNil(region)
        XCTAssertEqual(region?.width, 20)
        XCTAssertEqual(region?.height, 10)
    }

    func test_softCropOffset_defaultUpRight() {
        // Lots of room: default up-right (+x, -y).
        let o = softCropOffset(selection: CGRect(x: 100, y: 100, width: 40, height: 40),
                               imageBounds: CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(o, CGPoint(x: 12, y: -12))
    }

    func test_softCropOffset_flipsWhenNoRoom() {
        // Selection hugging top-right corner → must flip to down-left (-x, +y).
        let sel = CGRect(x: 356, y: 0, width: 40, height: 40)         // maxX=396, minY=0
        let o = softCropOffset(selection: sel,
                               imageBounds: CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(o, CGPoint(x: -12, y: 12))
    }

    /// C1 regression: scale=2 must yield a result 2× the visible rect in each dimension.
    func test_compositedRegion_scaleProducesScaledPixels() {
        let base = solidImage(40, 40)
        let region = compositedRegion(image: base, annotations: [], assets: [:],
                                      rect: CGRect(x: 5, y: 5, width: 10, height: 10),
                                      crop: nil, scale: 2)
        XCTAssertEqual(region?.width, 20)
        XCTAssertEqual(region?.height, 20)
    }
}
