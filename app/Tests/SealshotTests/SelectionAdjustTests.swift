import XCTest
import CoreGraphics
@testable import Sealshot

/// Geometry for the adjustable area-selection overlay. Coordinates are AppKit
/// non-flipped (origin bottom-left, y increases upward): "top" == maxY.
final class SelectionAdjustTests: XCTestCase {

    // A 1000×800 screen and a 200×150 selection at (100,100).
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
    private let minSize: CGFloat = 20

    // MARK: - hitTest

    func testHitTest_topLeftCorner() {
        XCTAssertEqual(SelectionAdjust.hitTest(CGPoint(x: 100, y: 250), in: rect, handleSize: 14), .topLeft)
    }

    func testHitTest_rightEdgeMidpoint() {
        XCTAssertEqual(SelectionAdjust.hitTest(CGPoint(x: 300, y: 175), in: rect, handleSize: 14), .right)
    }

    func testHitTest_topEdgeMidpoint() {
        XCTAssertEqual(SelectionAdjust.hitTest(CGPoint(x: 200, y: 250), in: rect, handleSize: 14), .top)
    }

    func testHitTest_interior() {
        XCTAssertEqual(SelectionAdjust.hitTest(CGPoint(x: 200, y: 175), in: rect, handleSize: 14), .interior)
    }

    func testHitTest_outsideReturnsNil() {
        XCTAssertNil(SelectionAdjust.hitTest(CGPoint(x: 700, y: 600), in: rect, handleSize: 14))
    }

    // MARK: - resize

    func testResize_rightEdge_growsWidth() {
        let r = SelectionAdjust.resize(rect, handle: .right, to: CGPoint(x: 400, y: 175), in: bounds, minSize: minSize)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 300, height: 150))
    }

    func testResize_leftEdge_movesOrigin() {
        let r = SelectionAdjust.resize(rect, handle: .left, to: CGPoint(x: 50, y: 175), in: bounds, minSize: minSize)
        XCTAssertEqual(r, CGRect(x: 50, y: 100, width: 250, height: 150))
    }

    func testResize_topRightCorner_movesTwoEdges() {
        let r = SelectionAdjust.resize(rect, handle: .topRight, to: CGPoint(x: 350, y: 300), in: bounds, minSize: minSize)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 250, height: 200))
    }

    func testResize_bottomEdge_movesBottom() {
        let r = SelectionAdjust.resize(rect, handle: .bottom, to: CGPoint(x: 200, y: 40), in: bounds, minSize: minSize)
        XCTAssertEqual(r, CGRect(x: 100, y: 40, width: 200, height: 210))
    }

    func testResize_clampsToMinSize_whenDraggingRightPastLeft() {
        let r = SelectionAdjust.resize(rect, handle: .right, to: CGPoint(x: 105, y: 175), in: bounds, minSize: minSize)
        // right can't cross within minSize of the fixed left edge (100).
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: minSize, height: 150))
    }

    func testResize_clampsToBounds() {
        let r = SelectionAdjust.resize(rect, handle: .right, to: CGPoint(x: 1200, y: 175), in: bounds, minSize: minSize)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 900, height: 150))  // right capped at 1000
    }

    // MARK: - move

    func testMove_translates() {
        let r = SelectionAdjust.move(rect, by: CGSize(width: 50, height: 30), in: bounds)
        XCTAssertEqual(r, CGRect(x: 150, y: 130, width: 200, height: 150))
    }

    func testMove_clampsAtLeftEdge() {
        let r = SelectionAdjust.move(rect, by: CGSize(width: -200, height: 0), in: bounds)
        XCTAssertEqual(r, CGRect(x: 0, y: 100, width: 200, height: 150))
    }

    func testMove_clampsAtRightEdge() {
        let r = SelectionAdjust.move(rect, by: CGSize(width: 900, height: 0), in: bounds)
        XCTAssertEqual(r, CGRect(x: 800, y: 100, width: 200, height: 150))  // 1000 - 200
    }

    // MARK: - seededRect

    func testSeededRect_centeredOnPoint() {
        let r = SelectionAdjust.seededRect(around: CGPoint(x: 500, y: 400),
                                           default: CGSize(width: 240, height: 150), in: bounds)
        XCTAssertEqual(r, CGRect(x: 380, y: 325, width: 240, height: 150))
    }

    func testSeededRect_clampsIntoBoundsNearCorner() {
        let r = SelectionAdjust.seededRect(around: CGPoint(x: 10, y: 10),
                                           default: CGSize(width: 240, height: 150), in: bounds)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 240, height: 150))
    }

    // MARK: - controlBarRects

    func testControlBar_sitsBelowWhenRoom() {
        let bars = SelectionAdjust.controlBarRects(for: rect, in: bounds)
        let size = SelectionAdjust.controlButtonSize
        let gap = SelectionAdjust.controlGap
        // Capture is right-anchored to the rect, cancel sits to its left, both
        // below the rect's bottom edge.
        XCTAssertEqual(bars.capture, CGRect(x: rect.maxX - size, y: rect.minY - gap - size, width: size, height: size))
        XCTAssertEqual(bars.cancel, CGRect(x: rect.maxX - size - gap - size, y: rect.minY - gap - size, width: size, height: size))
    }

    func testControlBar_flipsAboveWhenNearBottom() {
        let low = CGRect(x: 100, y: 5, width: 200, height: 150)   // no room below
        let bars = SelectionAdjust.controlBarRects(for: low, in: bounds)
        let size = SelectionAdjust.controlButtonSize
        let gap = SelectionAdjust.controlGap
        XCTAssertEqual(bars.capture.origin.y, low.maxY + gap)
        XCTAssertEqual(bars.cancel.origin.y, low.maxY + gap)
        XCTAssertEqual(bars.capture.height, size)
    }
}
