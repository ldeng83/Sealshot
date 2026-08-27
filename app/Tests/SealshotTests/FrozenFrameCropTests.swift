import XCTest
import CoreGraphics
@testable import Sealshot

/// Geometry for cropping a selection out of a frozen display image.
/// View-local rects are AppKit-style (bottom-left origin, points); image pixel
/// rects are top-left origin.
final class FrozenFrameCropTests: XCTestCase {

    // MARK: - pixelRect (view-local points → image pixels)

    func testPixelRect_retina2x_flipsAndScales() {
        // 1000×800pt view, 2000×1600px image. A 200×150 rect at (100,100):
        // top edge at y=250 → image top = (800-250)*2 = 1100.
        let px = FrozenFrameCrop.pixelRect(
            viewLocal: CGRect(x: 100, y: 100, width: 200, height: 150),
            viewSize: CGSize(width: 1000, height: 800),
            imageWidth: 2000, imageHeight: 1600)
        XCTAssertEqual(px, CGRect(x: 200, y: 1100, width: 400, height: 300))
    }

    func testPixelRect_1x_isFlipOnly() {
        let px = FrozenFrameCrop.pixelRect(
            viewLocal: CGRect(x: 10, y: 20, width: 30, height: 40),
            viewSize: CGSize(width: 1000, height: 800),
            imageWidth: 1000, imageHeight: 800)
        XCTAssertEqual(px, CGRect(x: 10, y: 800 - 60, width: 30, height: 40))
    }

    func testPixelRect_clampsToImageBounds() {
        // Rect hangs off the right/top of the view.
        let px = FrozenFrameCrop.pixelRect(
            viewLocal: CGRect(x: 900, y: 700, width: 300, height: 300),
            viewSize: CGSize(width: 1000, height: 800),
            imageWidth: 2000, imageHeight: 1600)
        XCTAssertEqual(px.minX, 1800)
        XCTAssertEqual(px.minY, 0)            // clipped at the image top
        XCTAssertEqual(px.maxX, 2000)         // clipped at the right edge
        XCTAssertEqual(px.maxY, 200)          // (800-700)*2
    }

    func testPixelRect_roundsFractionalPoints() {
        let px = FrozenFrameCrop.pixelRect(
            viewLocal: CGRect(x: 10.3, y: 10.3, width: 50.4, height: 50.4),
            viewSize: CGSize(width: 1000, height: 800),
            imageWidth: 2000, imageHeight: 1600)
        XCTAssertEqual(px.origin.x.truncatingRemainder(dividingBy: 1), 0)
        XCTAssertEqual(px.origin.y.truncatingRemainder(dividingBy: 1), 0)
        XCTAssertEqual(px.width.truncatingRemainder(dividingBy: 1), 0)
        XCTAssertEqual(px.height.truncatingRemainder(dividingBy: 1), 0)
    }

    // MARK: - viewLocalRect (image pixels → view-local points; inverse of pixelRect)

    func testViewLocalRect_isInverseOfPixelRect() {
        let viewSize = CGSize(width: 1000, height: 800)
        let original = CGRect(x: 100, y: 100, width: 200, height: 150)
        let px = FrozenFrameCrop.pixelRect(
            viewLocal: original, viewSize: viewSize, imageWidth: 2000, imageHeight: 1600)
        let back = FrozenFrameCrop.viewLocalRect(
            pixelRect: px, viewSize: viewSize, imageWidth: 2000, imageHeight: 1600)
        XCTAssertEqual(back, original)
    }

    // MARK: - windowViewLocalRect (SCWindow global top-left frame → view-local)

    func testWindowViewLocalRect_primaryScreen() {
        // Screen (0,0,1000,800); window CG frame (100, 50, 300, 200):
        // viewLocalY = 800 - 50 - 200 = 550.
        let local = FrozenFrameCrop.windowViewLocalRect(
            windowFrame: CGRect(x: 100, y: 50, width: 300, height: 200),
            screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            primaryMaxY: 800)
        XCTAssertEqual(local, CGRect(x: 100, y: 550, width: 300, height: 200))
    }

    func testWindowViewLocalRect_secondaryScreenOffset() {
        // Same-height screen at x=1000; window at global x=1100 → local x=100.
        let local = FrozenFrameCrop.windowViewLocalRect(
            windowFrame: CGRect(x: 1100, y: 50, width: 300, height: 200),
            screenFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
            primaryMaxY: 800)
        XCTAssertEqual(local.origin.x, 100)
        XCTAssertEqual(local.origin.y, 550)
    }

    func testWindowViewLocalRect_monitorAbovePrimary() {
        // Primary (0,0,1000,800); external ABOVE it: AppKit frame
        // (0, 800, 1600, 900). A window on the external whose CG top is
        // y = -800 (i.e. 100 pt below the external's top edge, which sits at
        // CG y = -900): AppKit bottom = 800 - (-800) - 200 = 1400 →
        // view-local y = 1400 - 800 = 600.
        let local = FrozenFrameCrop.windowViewLocalRect(
            windowFrame: CGRect(x: 100, y: -800, width: 300, height: 200),
            screenFrame: CGRect(x: 0, y: 800, width: 1600, height: 900),
            primaryMaxY: 800)
        XCTAssertEqual(local, CGRect(x: 100, y: 600, width: 300, height: 200))
    }

    // MARK: - crop (end-to-end on a tiny image)

    func testCrop_extractsExpectedPixelRegion() {
        // 4×4 image; crop the top-left 2×2 (view-local: x 0..2, y 2..4).
        let img = makeImage(width: 4, height: 4)
        let cropped = FrozenFrameCrop.crop(
            img,
            viewLocal: CGRect(x: 0, y: 2, width: 2, height: 2),
            viewSize: CGSize(width: 4, height: 4))
        XCTAssertEqual(cropped?.width, 2)
        XCTAssertEqual(cropped?.height, 2)
    }

    func testCrop_zeroSizeReturnsNil() {
        let img = makeImage(width: 4, height: 4)
        let cropped = FrozenFrameCrop.crop(
            img,
            viewLocal: CGRect(x: 1, y: 1, width: 0, height: 0),
            viewSize: CGSize(width: 4, height: 4))
        XCTAssertNil(cropped)
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}
