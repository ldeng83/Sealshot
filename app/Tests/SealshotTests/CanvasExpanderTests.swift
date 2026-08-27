import XCTest
@testable import Sealshot

final class CanvasExpanderTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // Fully inside → no expansion.
    func testInside_noExpansion() {
        let box = CGRect(x: 100, y: 100, width: 200, height: 150)
        XCTAssertNil(CanvasExpander.expandedViewport(current: viewport, annotationBounds: box))
    }

    // A hair over the edge (< epsilon) → no expansion.
    func testTinyOverhang_noExpansion() {
        let box = CGRect(x: 999.8, y: 100, width: 0.3, height: 10)  // maxX 1000.1
        XCTAssertNil(CanvasExpander.expandedViewport(current: viewport, annotationBounds: box))
    }

    // Off the right/bottom → viewport grows on that side, no content shift.
    func testOffRightBottom_growsNoShift() {
        let box = CGRect(x: 900, y: 700, width: 200, height: 200)  // maxX 1100, maxY 900
        let e = CanvasExpander.expandedViewport(current: viewport, annotationBounds: box)
        XCTAssertEqual(e?.shift, .zero)
        XCTAssertEqual(e?.viewport, CGRect(x: 0, y: 0, width: 1100, height: 900))
    }

    // Off the left/top → viewport origin goes NEGATIVE (past the source) and
    // content shifts by the overflow.
    func testOffLeftTop_viewportGoesNegative_contentShifts() {
        let box = CGRect(x: -40, y: -25, width: 100, height: 100)
        let e = CanvasExpander.expandedViewport(current: viewport, annotationBounds: box)
        XCTAssertEqual(e?.shift, CGVector(dx: 40, dy: 25))
        // origin -40,-25; width 1000+40 (right overflow 0), height 800+25
        XCTAssertEqual(e?.viewport, CGRect(x: -40, y: -25, width: 1040, height: 825))
    }

    // Growing from an already-cropped viewport keeps the crop's origin.
    func testExpandFromCroppedViewport() {
        let cropped = CGRect(x: 200, y: 150, width: 300, height: 200)  // visible = 300x200
        let box = CGRect(x: -30, y: 100, width: 50, height: 50)        // 30 past the left
        let e = CanvasExpander.expandedViewport(current: cropped, annotationBounds: box)
        XCTAssertEqual(e?.shift, CGVector(dx: 30, dy: 0))
        XCTAssertEqual(e?.viewport, CGRect(x: 170, y: 150, width: 330, height: 200))
    }

    // In-bounds viewport → plain crop of the source at native scale.
    func testViewportBase_inBounds() {
        let base = solidImage(width: 200, height: 160)
        let out = CanvasExpander.viewportBase(
            from: base, crop: CGRect(x: 20, y: 10, width: 100, height: 80), contentClip: nil, baseScale: 1)
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 80)
    }

    // Overhanging viewport → composited at viewport size (transparent margin).
    func testViewportBase_overhang() {
        let base = solidImage(width: 100, height: 80)
        let out = CanvasExpander.viewportBase(
            from: base, crop: CGRect(x: -20, y: -10, width: 140, height: 100), contentClip: nil, baseScale: 1)
        XCTAssertEqual(out.width, 140)
        XCTAssertEqual(out.height, 100)
    }

    private func solidImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}
