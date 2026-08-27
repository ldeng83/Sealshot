import XCTest
import CoreGraphics
@testable import Sealshot

/// Pen path handling: Douglas–Peucker simplification, anchor-index selection
/// (still used for blur-freehand vertices), and bounding-box resize handles.
final class PenAnchorTests: XCTestCase {

    // MARK: Douglas–Peucker simplification

    func testSimplify_straightRun_collapsesToEndpoints() {
        let pts = (0...10).map { CGPoint(x: CGFloat($0) * 10, y: 0) }   // colinear
        let s = PathSimplify.simplify(pts, epsilon: 1)
        XCTAssertEqual(s, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
    }

    func testSimplify_keepsCorner() {
        // An L: the corner is far from the start–end line, so it's kept.
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 1), CGPoint(x: 100, y: 0),
                   CGPoint(x: 100, y: 100)]
        let s = PathSimplify.simplify(pts, epsilon: 5)
        XCTAssertEqual(s.first, CGPoint(x: 0, y: 0))
        XCTAssertEqual(s.last, CGPoint(x: 100, y: 100))
        XCTAssertTrue(s.contains(CGPoint(x: 100, y: 0)), "the corner must be kept")
        XCTAssertFalse(s.contains(CGPoint(x: 50, y: 1)), "the near-colinear point should drop")
    }

    func testSimplifiedPenPath_cappedAtMaxAnchors() {
        // A dense zigzag that DP can't reduce below the cap at small epsilon.
        let pts = (0..<400).map { CGPoint(x: CGFloat($0), y: CGFloat($0 % 2) * 40) }
        let s = PathSimplify.simplifiedPenPath(pts)
        XCTAssertLessThanOrEqual(s.count, PathSimplify.maxPenAnchors)
        XCTAssertEqual(s.first, pts.first)
        XCTAssertEqual(s.last, pts.last)
    }

    // MARK: Anchor index selection

    func testAnchorIndices_underCap_returnsAll() {
        XCTAssertEqual(PathSimplify.anchorIndices(count: 5, max: 24), [0, 1, 2, 3, 4])
    }

    func testAnchorIndices_overCap_subsamplesWithEndpoints() {
        let idx = PathSimplify.anchorIndices(count: 200, max: 10)
        XCTAssertEqual(idx.count, 10)
        XCTAssertEqual(idx.first, 0)
        XCTAssertEqual(idx.last, 199)
        XCTAssertEqual(idx, idx.sorted())
        XCTAssertEqual(Set(idx).count, idx.count, "indices must be unique")
    }

    // MARK: Handles

    private func pen(_ pts: [CGPoint]) -> Annotation {
        Annotation(geometry: .pen(points: pts),
                   style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 4))
    }

    func testHitTestHandles_pen_returnsBoundingBoxHandles() {
        // Pen now exposes the 8 bounding-box resize handles (like ellipse),
        // not a dot per vertex — so the drawn line reads smooth.
        let a = pen([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0)])
        // Bounding box spans (0,0)–(100,50).
        XCTAssertEqual(hitTestHandles(of: a, at: CGPoint(x: 0, y: 0), handleSize: 12), .topLeft)
        XCTAssertEqual(hitTestHandles(of: a, at: CGPoint(x: 100, y: 50), handleSize: 12), .bottomRight)
        XCTAssertEqual(hitTestHandles(of: a, at: CGPoint(x: 0, y: 25), handleSize: 12), .left)
        // Interior point (away from every box handle) is not a handle hit.
        XCTAssertNil(hitTestHandles(of: a, at: CGPoint(x: 25, y: 25), handleSize: 12))
    }
}
