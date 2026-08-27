import XCTest
import CoreGraphics
@testable import Sealshot

/// Pure-layer behavior of the freehand pen geometry (`.pen(points:)`).
final class PenToolTests: XCTestCase {

    private func pen(_ pts: [CGPoint], width: CGFloat = 4) -> Annotation {
        Annotation(geometry: .pen(points: pts),
                   style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: width))
    }

    func testCodecRoundTrip_pen() throws {
        let a = pen([CGPoint(x: 1, y: 2), CGPoint(x: 30, y: 40), CGPoint(x: 70, y: 5)])
        let data = try encodeAnnotations([a], crop: nil)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.annotations, [a])
    }

    func testGeometryBounds_pen_isPointsBoundingRect() {
        let g = Geometry.pen(points: [CGPoint(x: 10, y: 50), CGPoint(x: 40, y: 5), CGPoint(x: 70, y: 30)])
        XCTAssertEqual(geometryBounds(g), CGRect(x: 10, y: 5, width: 60, height: 45))
    }

    func testTranslate_pen_offsetsEveryPoint() {
        let g = Geometry.pen(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 20)])
        guard case let .pen(pts) = translatedGeometry(g, by: CGVector(dx: 5, dy: -3)) else {
            return XCTFail("expected .pen")
        }
        XCTAssertEqual(pts, [CGPoint(x: 5, y: -3), CGPoint(x: 15, y: 17)])
    }

    func testHitTest_pen_nearSegmentHits_farMisses() {
        // Path is an L: (0,0)->(100,0)->(100,100).
        let a = pen([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)])
        // Point near the middle of the first segment.
        XCTAssertEqual(hitTestAnnotations([a], at: CGPoint(x: 50, y: 3), tolerance: 6), a.id)
        // Point near the second segment.
        XCTAssertEqual(hitTestAnnotations([a], at: CGPoint(x: 97, y: 50), tolerance: 6), a.id)
        // Point far from any segment (interior of the L's corner gap).
        XCTAssertNil(hitTestAnnotations([a], at: CGPoint(x: 40, y: 60), tolerance: 6))
    }
}
