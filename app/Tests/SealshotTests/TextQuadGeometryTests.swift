import XCTest
import CoreGraphics
@testable import Sealshot

/// Geometry behind the tilt-following selection highlight: tightening the line
/// quad (issue 3) and carving a sub-quad for the selected character range so the
/// fill stays inside the outline (issue 4) and follows the tilt (issue 5).
final class TextQuadGeometryTests: XCTestCase {

    /// An axis-aligned line quad (top-left origin: top edge has the smaller y).
    private func axisQuad() -> TextQuad {
        TextQuad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 1, y: 0),
                 bottomRight: CGPoint(x: 1, y: 0.1), bottomLeft: CGPoint(x: 0, y: 0.1))
    }

    // MARK: span (selection sub-quad)

    func testSpanCarvesLeftHalf() {
        let s = axisQuad().span(fromFraction: 0.0, toFraction: 0.5)
        XCTAssertEqual(s.topLeft.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(s.topRight.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.bottomRight.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.bottomLeft.x, 0.0, accuracy: 1e-9)
        // Vertically it spans the full line height — only x is sliced.
        XCTAssertEqual(s.topLeft.y, 0.0, accuracy: 1e-9)
        XCTAssertEqual(s.bottomLeft.y, 0.1, accuracy: 1e-9)
    }

    func testSpanFollowsTilt() {
        // Tilted line: right side higher (smaller y) than left.
        let q = TextQuad(topLeft: CGPoint(x: 0, y: 0.10), topRight: CGPoint(x: 1, y: 0.00),
                         bottomRight: CGPoint(x: 1, y: 0.10), bottomLeft: CGPoint(x: 0, y: 0.20))
        let s = q.span(fromFraction: 0.0, toFraction: 0.5)
        // The right edge of the half-selection sits at the tilted midpoint, not
        // a flat horizontal — its y is between the left and full-right y.
        XCTAssertEqual(s.topRight.y, 0.05, accuracy: 1e-9)
        XCTAssertLessThan(s.topRight.y, s.topLeft.y)
    }

    func testSpanWithinOutline() {
        // Every span corner lies on an edge of the parent quad → inside it.
        let q = axisQuad()
        let s = q.span(fromFraction: 0.25, toFraction: 0.75)
        for p in [s.topLeft, s.topRight, s.bottomLeft, s.bottomRight] {
            XCTAssertGreaterThanOrEqual(p.x, q.topLeft.x - 1e-9)
            XCTAssertLessThanOrEqual(p.x, q.topRight.x + 1e-9)
            XCTAssertGreaterThanOrEqual(p.y, q.topLeft.y - 1e-9)
            XCTAssertLessThanOrEqual(p.y, q.bottomLeft.y + 1e-9)
        }
    }

    // MARK: insetVertically (tighten)

    func testInsetVerticallyShrinksTowardCenterline() {
        let q = TextQuad(topLeft: CGPoint(x: 0, y: 0.2), topRight: CGPoint(x: 1, y: 0.2),
                         bottomRight: CGPoint(x: 1, y: 0.4), bottomLeft: CGPoint(x: 0, y: 0.4))
        let t = q.insetVertically(by: 0.5)   // remove 25% off top, 25% off bottom
        XCTAssertEqual(t.topLeft.y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(t.bottomLeft.y, 0.35, accuracy: 1e-9)
        // x is untouched — only vertical tightening.
        XCTAssertEqual(t.topLeft.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(t.topRight.x, 1.0, accuracy: 1e-9)
    }
}
