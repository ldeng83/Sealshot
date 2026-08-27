import XCTest
import CoreGraphics
@testable import Sealshot

final class FocusCropGeometryTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let start  = CGRect(x: 0, y: 0, width: 100, height: 100)

    // MARK: - focusHandleHit

    private let v = CGRect(x: 0, y: 0, width: 100, height: 80)

    func testEdgeHitAnywhereAlongEdgeSelectsEdgeHandle() {
        // Points near an edge but away from corners pick that edge's handle.
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: 30, y: 1),  in: v, cornerRadius: 14, edgeTolerance: 7), .top)
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: 70, y: 1),  in: v, cornerRadius: 14, edgeTolerance: 7), .top)
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: 50, y: 79), in: v, cornerRadius: 14, edgeTolerance: 7), .bottom)
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: 1,  y: 40), in: v, cornerRadius: 14, edgeTolerance: 7), .left)
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: 99, y: 40), in: v, cornerRadius: 14, edgeTolerance: 7), .right)
    }

    func testCornerHitWinsOverEdge() {
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: 3,  y: 3),  in: v, cornerRadius: 14, edgeTolerance: 7), .topLeft)
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: 97, y: 3),  in: v, cornerRadius: 14, edgeTolerance: 7), .topRight)
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: 3,  y: 77), in: v, cornerRadius: 14, edgeTolerance: 7), .bottomLeft)
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: 97, y: 77), in: v, cornerRadius: 14, edgeTolerance: 7), .bottomRight)
    }

    func testInteriorAndFarPointsMiss() {
        XCTAssertNil(focusHandleHit(at: CGPoint(x: 50, y: 40), in: v, cornerRadius: 14, edgeTolerance: 7)) // center
        XCTAssertNil(focusHandleHit(at: CGPoint(x: 50, y: 20), in: v, cornerRadius: 14, edgeTolerance: 7)) // interior, > grab radius
    }

    func testGrabsDotFromJustOutsideTheRect() {
        // A point beyond the boundary but within the grab radius of a boundary
        // dot still grabs it — needed so a focus crop that fills the image can
        // be grabbed from just outside the image edge, not only from inside.
        // left midpoint dot at (0, 40); (-10, 40) is 10pt outside, < radius 14.
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: -10, y: 40), in: v, cornerRadius: 14, edgeTolerance: 7), .left)
        // topLeft corner (0, 0); (-8, -8) is outside, dist ≈ 11.3 < 14.
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: -8, y: -8), in: v, cornerRadius: 14, edgeTolerance: 7), .topLeft)
    }

    func testNearEdgeMidpointDotGrabsThatEdge() {
        // A point within the grab radius of an edge MIDPOINT dot activates that
        // edge even when it's further from the edge line than `edgeTolerance` —
        // the dot itself is grabbable as a disc, so "cursor on the dot" works.
        // top midpoint dot is at (50, 0); (50, 12) is 12pt away, < radius 14.
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: 50, y: 12), in: v, cornerRadius: 14, edgeTolerance: 7), .top)
        // left midpoint dot at (0, 40); (11, 40) is within the disc.
        XCTAssertEqual(focusHandleHit(at: CGPoint(x: 11, y: 40), in: v, cornerRadius: 14, edgeTolerance: 7), .left)
    }

    func testTopLeftShrinksInward() {
        let r = resizeFocus(start: start, handle: .topLeft,
                            to: CGPoint(x: 20, y: 30), minSize: 10, bounds: bounds)
        XCTAssertEqual(r, CGRect(x: 20, y: 30, width: 80, height: 70))
    }

    func testCanGrowBeyondStart() {
        // Bidirectional: dragging a corner outward enlarges the focus rect.
        let inner = CGRect(x: 25, y: 25, width: 50, height: 50)
        let r = resizeFocus(start: inner, handle: .topLeft,
                            to: CGPoint(x: 5, y: 10), minSize: 10, bounds: bounds)
        XCTAssertEqual(r, CGRect(x: 5, y: 10, width: 70, height: 65))
    }

    func testGrowClampsToImageBounds() {
        // Dragging past the image edge clamps to the image, never beyond.
        let inner = CGRect(x: 25, y: 25, width: 50, height: 50)
        let r = resizeFocus(start: inner, handle: .topLeft,
                            to: CGPoint(x: -40, y: -40), minSize: 10, bounds: bounds)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 75, height: 75))
    }

    func testRightEdgeGrowsOutward() {
        let inner = CGRect(x: 20, y: 20, width: 40, height: 40)
        let r = resizeFocus(start: inner, handle: .right,
                            to: CGPoint(x: 90, y: 50), minSize: 10, bounds: bounds)
        XCTAssertEqual(r, CGRect(x: 20, y: 20, width: 70, height: 40))
    }

    func testMinSizeEnforced() {
        let r = resizeFocus(start: start, handle: .right,
                            to: CGPoint(x: 3, y: 50), minSize: 10, bounds: bounds)
        XCTAssertEqual(r.width, 10, accuracy: 0.001)
        XCTAssertEqual(r.minX, 0, accuracy: 0.001)
    }

    func testCannotInvertPastOppositeEdge() {
        // Dragging the left edge far right past the right edge is bounded by minSize.
        let inner = CGRect(x: 20, y: 20, width: 40, height: 40)
        let r = resizeFocus(start: inner, handle: .left,
                            to: CGPoint(x: 90, y: 50), minSize: 10, bounds: bounds)
        XCTAssertEqual(r.maxX, 60, accuracy: 0.001)   // right edge fixed
        XCTAssertEqual(r.width, 10, accuracy: 0.001)  // pinned to minSize
    }

    // MARK: - focusBracketSegments (viewfinder-style anchors)

    private let frame = CGRect(x: 0, y: 0, width: 100, height: 80)

    func testEachCornerHasTwoArmsPointingInwardAlongEdges() {
        let segs = focusBracketSegments(in: frame, arm: 12, tick: 10)
        // Top-left corner: one arm to the right, one arm downward — both start at the corner.
        XCTAssertTrue(segs.contains(FocusBracketSegment(a: CGPoint(x: 0, y: 0), b: CGPoint(x: 12, y: 0))))
        XCTAssertTrue(segs.contains(FocusBracketSegment(a: CGPoint(x: 0, y: 0), b: CGPoint(x: 0, y: 12))))
        // Bottom-right corner: one arm to the left, one arm upward.
        XCTAssertTrue(segs.contains(FocusBracketSegment(a: CGPoint(x: 100, y: 80), b: CGPoint(x: 88, y: 80))))
        XCTAssertTrue(segs.contains(FocusBracketSegment(a: CGPoint(x: 100, y: 80), b: CGPoint(x: 100, y: 68))))
    }

    func testEdgeTicksAreCenteredAndCollinearWithTheirEdge() {
        let segs = focusBracketSegments(in: frame, arm: 12, tick: 10)
        // Top edge: short horizontal tick centred on the midpoint (50, 0).
        XCTAssertTrue(segs.contains(FocusBracketSegment(a: CGPoint(x: 45, y: 0), b: CGPoint(x: 55, y: 0))))
        // Left edge: short vertical tick centred on the midpoint (0, 40).
        XCTAssertTrue(segs.contains(FocusBracketSegment(a: CGPoint(x: 0, y: 35), b: CGPoint(x: 0, y: 45))))
    }

    func testProducesEightCornerArmsAndFourEdgeTicks() {
        let segs = focusBracketSegments(in: frame, arm: 12, tick: 10)
        XCTAssertEqual(segs.count, 12)   // 4 corners × 2 arms + 4 edge ticks
    }
}
