import XCTest
import CoreGraphics
@testable import Sealshot

final class MultiDisplayStitcherTests: XCTestCase {

    private func solid(_ w: Int, _ h: Int, _ color: CGColor) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func gray(_ w: Int, _ h: Int, _ g: CGFloat) -> CGImage {
        solid(w, h, CGColor(gray: g, alpha: 1))
    }

    /// Flatten a CGImage into RGBA8 bytes for pixel inspection.
    private func rgba(_ img: CGImage) -> (w: Int, h: Int, px: [UInt8]) {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, px)
    }

    /// Number of rows that are entirely `isBlue` across the full width. Row order
    /// (top- vs bottom-first) does not matter — we only count matching rows, which
    /// is invariant to a vertical flip.
    private func fullBlueRowCount(_ img: CGImage) -> Int {
        let (w, h, px) = rgba(img)
        var count = 0
        for y in 0..<h {
            var allBlue = true
            for x in 0..<w {
                let o = (y * w + x) * 4
                if !(px[o] < 60 && px[o + 1] < 60 && px[o + 2] > 190 && px[o + 3] > 190) {
                    allBlue = false; break
                }
            }
            if allBlue { count += 1 }
        }
        return count
    }

    func test_unionSizeOfTwoSideBySideDisplays() throws {
        // Left monitor at x=0, right monitor at x=100, both 100 pt tall, scale 1.
        let out = try XCTUnwrap(MultiDisplayStitcher.stitch([
            (CGRect(x: 0, y: 0, width: 100, height: 100), gray(100, 100, 0.2)),
            (CGRect(x: 100, y: 0, width: 50, height: 100), gray(50, 100, 0.8))],
            outputScale: 1))
        XCTAssertEqual(out.width, 150)
        XCTAssertEqual(out.height, 100)
    }

    func test_unionAccountsForNegativeOriginDisplay() throws {
        // A second monitor to the LEFT (negative x) of the primary.
        let out = try XCTUnwrap(MultiDisplayStitcher.stitch([
            (CGRect(x: -80, y: 20, width: 80, height: 60), gray(80, 60, 0.5)),
            (CGRect(x: 0, y: 0, width: 100, height: 100), gray(100, 100, 0.3))],
            outputScale: 1))
        XCTAssertEqual(out.width, 180)    // x: -80 … 100
        XCTAssertEqual(out.height, 100)   // y: 0 … 100
    }

    func test_outputScaleMultipliesUnionSize() throws {
        let out = try XCTUnwrap(MultiDisplayStitcher.stitch([
            (CGRect(x: 0, y: 0, width: 100, height: 80), gray(200, 160, 0.5))],
            outputScale: 2))
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 160)
    }

    /// Regression: mixed backing-scale displays must be laid out in point-space,
    /// each image resampled to its point-footprint × outputScale. The bug sized
    /// tiles by raw native pixels while offsetting by points × one scale, so a
    /// low-DPI display was squashed and left black gaps.
    ///
    /// Layout: A (2× main) 100×100 pt at (0,0); B (1× external) 150×60 pt at
    /// (0,100), stacked above A. outputScale = 2 → union 150×160 pt → 300×320 px.
    /// B (150×60 pt) must fill 300×120 px — full union width, 120 px tall — NOT its
    /// native 150×60. Under the old bug B stays 150 px wide, so NO row is full-width
    /// blue.
    func test_mixedScale_lowDPIDisplayFillsItsPointFootprint() throws {
        let a = solid(200, 200, CGColor(red: 1, green: 0, blue: 0, alpha: 1))   // 2× native px
        let b = solid(150, 60, CGColor(red: 0, green: 0, blue: 1, alpha: 1))    // 1× native px
        let out = try XCTUnwrap(MultiDisplayStitcher.stitch([
            (CGRect(x: 0, y: 0, width: 100, height: 100), a),
            (CGRect(x: 0, y: 100, width: 150, height: 60), b)],
            outputScale: 2))

        XCTAssertEqual(out.width, 300)    // 150 pt × 2
        XCTAssertEqual(out.height, 320)   // 160 pt × 2

        // B must occupy 120 full-width blue rows (60 pt × 2). Allow a couple of
        // rows of edge blending at the A/B boundary. The old code produced 0.
        let blueRows = fullBlueRowCount(out)
        XCTAssertGreaterThanOrEqual(blueRows, 116, "low-DPI tile not scaled to its point footprint (got \(blueRows) full-width blue rows, expected ~120)")
        XCTAssertLessThanOrEqual(blueRows, 122)
    }

    func test_emptyReturnsNil() {
        XCTAssertNil(MultiDisplayStitcher.stitch([], outputScale: 2))
    }

    func test_nonPositiveScaleReturnsNil() {
        XCTAssertNil(MultiDisplayStitcher.stitch([
            (CGRect(x: 0, y: 0, width: 10, height: 10), gray(10, 10, 0.5))], outputScale: 0))
    }
}
