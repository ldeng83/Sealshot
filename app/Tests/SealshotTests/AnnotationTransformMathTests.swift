import XCTest
@testable import Sealshot

final class AnnotationTransformMathTests: XCTestCase {
    private let center = CGPoint(x: 100, y: 100)

    func testIdentity_mapsPointsUnchanged() {
        let m = transformMatrix(for: AnnotationTransform(), center: center)
        XCTAssertEqual(CGPoint(x: 7, y: 9).applying(m), CGPoint(x: 7, y: 9))
    }

    func testRotation90_clockwiseInYDownSpace() {
        // y-down (canvas/image) space: +90° sends a point right of center to
        // below center.
        let m = transformMatrix(for: AnnotationTransform(rotationDegrees: 90),
                                center: center)
        let p = CGPoint(x: 110, y: 100).applying(m)
        XCTAssertEqual(p.x, 100, accuracy: 0.001)
        XCTAssertEqual(p.y, 110, accuracy: 0.001)
    }

    func testFlipH_mirrorsAboutVerticalAxisThroughCenter() {
        let m = transformMatrix(for: AnnotationTransform(flipH: true), center: center)
        let p = CGPoint(x: 110, y: 90).applying(m)
        XCTAssertEqual(p.x, 90, accuracy: 0.001)
        XCTAssertEqual(p.y, 90, accuracy: 0.001)
    }

    func testRoundTrip_inverseRecoversPoint() {
        let t = AnnotationTransform(rotationDegrees: 37, flipH: true, flipV: false)
        let m = transformMatrix(for: t, center: center)
        let p = CGPoint(x: 123, y: 45)
        let back = p.applying(m).applying(m.inverted())
        XCTAssertEqual(back.x, p.x, accuracy: 0.001)
        XCTAssertEqual(back.y, p.y, accuracy: 0.001)
    }

    func testTransformedAABB_rotated45Square() {
        let bounds = CGRect(x: 90, y: 90, width: 20, height: 20)   // center (100,100)
        let aabb = transformedAABB(bounds: bounds,
                                   transform: AnnotationTransform(rotationDegrees: 45))
        let d = 20 * sqrt(2.0)
        XCTAssertEqual(aabb.width, d, accuracy: 0.01)
        XCTAssertEqual(aabb.height, d, accuracy: 0.01)
        XCTAssertEqual(aabb.midX, 100, accuracy: 0.01)
        XCTAssertEqual(aabb.midY, 100, accuracy: 0.01)
    }
}
