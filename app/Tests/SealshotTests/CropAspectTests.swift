import XCTest
import CoreGraphics
@testable import Sealshot

final class CropAspectTests: XCTestCase {

    // 100x100 square, 16:9, anchored topLeft (0,0), big bounds → ratio preserved, anchor fixed
    func testAspect16_9_anchorTopLeft() {
        let rect   = CGRect(x: 0, y: 0, width: 100, height: 100)
        let anchor = CGPoint(x: 0, y: 0)
        let bounds = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        let r = aspectConstrainedRect(rect, aspect: 16.0 / 9.0, anchor: anchor, bounds: bounds)
        XCTAssertLessThan(abs(r.width / r.height - 16.0 / 9.0), 0.001, "ratio not preserved")
        XCTAssertEqual(r.minX, 0, accuracy: 0.001, "anchor X moved")
        XCTAssertEqual(r.minY, 0, accuracy: 0.001, "anchor Y moved")
    }

    // 80x40 rect, aspect 1:1, anchored topLeft → becomes a square, anchor fixed
    func testAspect1_1_squaresRect() {
        let rect   = CGRect(x: 10, y: 10, width: 80, height: 40)
        let anchor = CGPoint(x: 10, y: 10)
        let bounds = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        let r = aspectConstrainedRect(rect, aspect: 1.0, anchor: anchor, bounds: bounds)
        XCTAssertEqual(r.width, r.height, accuracy: 0.001, "not a square")
        XCTAssertEqual(r.minX, 10, accuracy: 0.001, "anchor X moved")
        XCTAssertEqual(r.minY, 10, accuracy: 0.001, "anchor Y moved")
    }

    // Rect near right edge: 16:9 would expand past bounds → stays inside, keeps ratio, anchor fixed
    func testBoundsClamping() {
        let rect   = CGRect(x: 90, y: 0, width: 20, height: 20)
        let anchor = CGPoint(x: 90, y: 0)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r = aspectConstrainedRect(rect, aspect: 16.0 / 9.0, anchor: anchor, bounds: bounds)
        XCTAssertLessThanOrEqual(r.maxX, bounds.maxX + 0.001, "right edge outside bounds")
        XCTAssertLessThanOrEqual(r.maxY, bounds.maxY + 0.001, "bottom edge outside bounds")
        XCTAssertGreaterThanOrEqual(r.minX, bounds.minX - 0.001, "left edge outside bounds")
        XCTAssertGreaterThanOrEqual(r.minY, bounds.minY - 0.001, "top edge outside bounds")
        XCTAssertLessThan(abs(r.width / r.height - 16.0 / 9.0), 0.001, "ratio not preserved after clamp")
        XCTAssertEqual(r.minX, 90, accuracy: 0.001, "anchor X moved")
        XCTAssertEqual(r.minY, 0, accuracy: 0.001, "anchor Y moved")
    }

    // Anchor at bottomRight: bottomRight stays fixed, rect grows up-left, ratio preserved
    func testAnchorBottomRight() {
        let rect   = CGRect(x: 0, y: 0, width: 100, height: 100)
        let anchor = CGPoint(x: rect.maxX, y: rect.maxY)  // (100, 100)
        let bounds = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        let r = aspectConstrainedRect(rect, aspect: 16.0 / 9.0, anchor: anchor, bounds: bounds)
        XCTAssertEqual(r.maxX, 100, accuracy: 0.001, "anchor X (maxX) moved")
        XCTAssertEqual(r.maxY, 100, accuracy: 0.001, "anchor Y (maxY) moved")
        XCTAssertLessThan(abs(r.width / r.height - 16.0 / 9.0), 0.001, "ratio not preserved")
    }
}
