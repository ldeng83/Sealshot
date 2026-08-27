import XCTest
import CoreGraphics
@testable import Sealshot

/// Synthetic-fixture tests for the frozen-frame boundary detector. Rects are
/// asserted in image pixel coordinates (top-left origin) with a tolerance of
/// 2× the downscale factor (the detector works at reduced resolution).
final class BoundaryDetectorTests: XCTestCase {

    private let tolerance: CGFloat = 8   // 2 × default downscale (4)

    /// One light card on a dark background → exactly that rect (± tolerance).
    func testDetect_singleCard() {
        let card = CGRect(x: 80, y: 120, width: 200, height: 120)
        let img = fixture(size: CGSize(width: 400, height: 300), cards: [card])
        let rects = BoundaryDetector.detect(in: img)
        XCTAssertTrue(containsRect(rects, near: card, tolerance: tolerance),
                      "expected a rect near \(card); got \(rects)")
    }

    /// Two separate cards → both found. Sizes sit above the detector's
    /// confidence floors (minSegmentLength / minRectSide at 4× downscale).
    func testDetect_twoCards() {
        let a = CGRect(x: 40, y: 40, width: 160, height: 120)
        let b = CGRect(x: 220, y: 170, width: 150, height: 110)
        let img = fixture(size: CGSize(width: 400, height: 300), cards: [a, b])
        let rects = BoundaryDetector.detect(in: img)
        XCTAssertTrue(containsRect(rects, near: a, tolerance: tolerance), "missing \(a); got \(rects)")
        XCTAssertTrue(containsRect(rects, near: b, tolerance: tolerance), "missing \(b); got \(rects)")
    }

    /// Detected edges snap to the true boundary at full resolution: a card at
    /// coordinates that are NOT multiples of the downscale factor must come
    /// back within ±2 px per side, not ±(2 × downscale).
    func testDetect_offGridCard_isPixelAccurate() {
        let card = CGRect(x: 83, y: 121, width: 205, height: 118)
        let img = fixture(size: CGSize(width: 400, height: 300), cards: [card])
        let rects = BoundaryDetector.detect(in: img)
        XCTAssertTrue(containsRect(rects, near: card, tolerance: 2),
                      "expected a rect within ±2px of \(card); got \(rects)")
    }

    /// A uniform image → no boundaries.
    func testDetect_uniformImage_findsNothing() {
        let img = fixture(size: CGSize(width: 400, height: 300), cards: [])
        XCTAssertTrue(BoundaryDetector.detect(in: img).isEmpty)
    }

    /// Expansion from a point inside the card snaps to the card's edges.
    func testExpand_insideCard_findsCard() {
        let card = CGRect(x: 80, y: 120, width: 200, height: 120)
        let img = fixture(size: CGSize(width: 400, height: 300), cards: [card])
        let rect = BoundaryDetector.expand(from: CGPoint(x: 180, y: 180), in: img)
        XCTAssertNotNil(rect)
        if let rect { XCTAssertTrue(isNear(rect, card, tolerance: tolerance), "got \(rect)") }
    }

    /// Expansion on a uniform image finds no edges → nil.
    func testExpand_uniform_returnsNil() {
        let img = fixture(size: CGSize(width: 400, height: 300), cards: [])
        XCTAssertNil(BoundaryDetector.expand(from: CGPoint(x: 200, y: 150), in: img))
    }

    // MARK: - Fixtures

    /// Dark background with light filled rects. `cards` are in image pixel
    /// coordinates (top-left origin); the CGContext's bottom-left origin is
    /// flipped accordingly.
    private func fixture(size: CGSize, cards: [CGRect]) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 4 * w, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        for card in cards {
            let flipped = CGRect(x: card.minX, y: size.height - card.maxY,
                                 width: card.width, height: card.height)
            ctx.fill(flipped)
        }
        return ctx.makeImage()!
    }

    private func isNear(_ a: CGRect, _ b: CGRect, tolerance t: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t &&
        abs(a.maxX - b.maxX) <= t && abs(a.maxY - b.maxY) <= t
    }

    private func containsRect(_ rects: [CGRect], near target: CGRect, tolerance t: CGFloat) -> Bool {
        rects.contains { isNear($0, target, tolerance: t) }
    }
}
