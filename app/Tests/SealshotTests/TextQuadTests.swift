import XCTest
import CoreGraphics
@testable import Sealshot

final class TextQuadTests: XCTestCase {

    func testFlipsToTopLeftOrigin() {
        // Vision corners are bottom-left origin: the visual "top" edge has the
        // larger y. Here top edge at ~0.7, bottom edge at ~0.5.
        let q = TextQuad.fromVisionCorners(
            topLeft: CGPoint(x: 0.1, y: 0.70),
            topRight: CGPoint(x: 0.9, y: 0.72),
            bottomLeft: CGPoint(x: 0.1, y: 0.50),
            bottomRight: CGPoint(x: 0.9, y: 0.52))

        // X is unchanged by the flip.
        XCTAssertEqual(q.topLeft.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(q.topRight.x, 0.9, accuracy: 1e-9)
        // Y flipped: 1 - 0.70 = 0.30.
        XCTAssertEqual(q.topLeft.y, 0.30, accuracy: 1e-9)
        XCTAssertEqual(q.bottomLeft.y, 0.50, accuracy: 1e-9)
        // In top-left origin the visual top is above (smaller y than) the bottom.
        XCTAssertLessThan(q.topLeft.y, q.bottomLeft.y)
    }

    func testPreservesTilt() {
        // A line tilted up to the right: in bottom-left origin the right edge has
        // a larger y than the left edge.
        let q = TextQuad.fromVisionCorners(
            topLeft: CGPoint(x: 0.1, y: 0.60),
            topRight: CGPoint(x: 0.9, y: 0.66),
            bottomLeft: CGPoint(x: 0.1, y: 0.50),
            bottomRight: CGPoint(x: 0.9, y: 0.56))

        // After flipping to top-left origin the tilt survives: the right edge
        // sits higher (smaller y) than the left edge, so the outline slants.
        XCTAssertLessThan(q.topRight.y, q.topLeft.y)
        XCTAssertLessThan(q.bottomRight.y, q.bottomLeft.y)
        XCTAssertNotEqual(q.topLeft.y, q.topRight.y, accuracy: 1e-6)
    }
}
