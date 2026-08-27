import XCTest
import CoreGraphics
@testable import Sealshot

/// Hit-testing in tilted-quad space, so clicking a row selects THAT row (not
/// the one above) even when the axis-aligned line boxes overlap.
final class QuadHitTestingTests: XCTestCase {

    private func axisQuad(top: CGFloat, bottom: CGFloat) -> TextQuad {
        TextQuad(topLeft: CGPoint(x: 0.2, y: top), topRight: CGPoint(x: 0.8, y: top),
                 bottomRight: CGPoint(x: 0.8, y: bottom), bottomLeft: CGPoint(x: 0.2, y: bottom))
    }

    // MARK: TextQuad.contains

    func testContainsPointInside() {
        XCTAssertTrue(axisQuad(top: 0.0, bottom: 0.1).contains(CGPoint(x: 0.5, y: 0.05)))
    }

    func testRejectsPointOutside() {
        let q = axisQuad(top: 0.0, bottom: 0.1)
        XCTAssertFalse(q.contains(CGPoint(x: 0.5, y: 0.3)))   // below
        XCTAssertFalse(q.contains(CGPoint(x: 0.9, y: 0.05)))  // right of the 0.2–0.8 span
    }

    func testContainsHandlesTilt() {
        // Slanted line: right edge higher (smaller y) than left.
        let q = TextQuad(topLeft: CGPoint(x: 0.0, y: 0.20), topRight: CGPoint(x: 1.0, y: 0.10),
                         bottomRight: CGPoint(x: 1.0, y: 0.20), bottomLeft: CGPoint(x: 0.0, y: 0.30))
        XCTAssertTrue(q.contains(CGPoint(x: 0.9, y: 0.14)))    // inside near the raised right end
        XCTAssertFalse(q.contains(CGPoint(x: 0.9, y: 0.28)))   // below the raised right end
    }

    // MARK: TextQuad.parameter (caret fraction)

    func testParameterEndsAndMiddle() {
        let q = axisQuad(top: 0.0, bottom: 0.1)
        XCTAssertEqual(q.parameter(at: CGPoint(x: 0.2, y: 0.05)), 0.0, accuracy: 1e-6)
        XCTAssertEqual(q.parameter(at: CGPoint(x: 0.8, y: 0.05)), 1.0, accuracy: 1e-6)
        XCTAssertEqual(q.parameter(at: CGPoint(x: 0.5, y: 0.05)), 0.5, accuracy: 1e-6)
    }

    // MARK: Layout line hit-testing reproduces the bug

    func testClickInLowerRowSelectsLowerRow() {
        // Two rows whose AXIS-ALIGNED boxes overlap (tall, like tilted lines),
        // but whose tight quads do not. A click clearly inside the lower row's
        // quad must resolve to the lower row — the reported off-by-one.
        let row0 = RecognizedLine(
            text: "AAAAA",
            box: CGRect(x: 0.2, y: 0.28, width: 0.6, height: 0.12),   // 0.28–0.40
            charBoxes: subdivideLineBox(CGRect(x: 0.2, y: 0.28, width: 0.6, height: 0.12), count: 5),
            quad: axisQuad(top: 0.30, bottom: 0.36))
        let row1 = RecognizedLine(
            text: "BBBBB",
            box: CGRect(x: 0.2, y: 0.36, width: 0.6, height: 0.12),   // 0.36–0.48 (overlaps row0 box)
            charBoxes: subdivideLineBox(CGRect(x: 0.2, y: 0.36, width: 0.6, height: 0.12), count: 5),
            quad: axisQuad(top: 0.40, bottom: 0.46))
        let layout = RecognizedTextLayout(lines: [row0, row1])

        let pos = layout.position(at: CGPoint(x: 0.5, y: 0.43))   // inside row1's quad
        XCTAssertEqual(pos.line, 1, "click inside the lower row should select the lower row")
    }
}
