import XCTest
@testable import Sealshot

final class TransformHitTestTests: XCTestCase {

    private func rect90() -> Annotation {
        var a = Annotation(
            geometry: .rectangle(rect: CGRect(x: 80, y: 95, width: 40, height: 10)),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 2,
                         fillColor: SerializableColor(NSColor.red)))
        a.transform = AnnotationTransform(rotationDegrees: 90)
        return a
    }

    func testBodyHit_usesRotatedFootprint() {
        // Center (100,100): the rect is 40 wide × 10 tall unrotated; rotated
        // 90° its footprint is 10 wide × 40 tall.
        let a = rect90()
        XCTAssertNotNil(hitTestAnnotations([a], at: CGPoint(x: 100, y: 115), tolerance: 1),
                        "point inside ROTATED footprint must hit")
        XCTAssertNil(hitTestAnnotations([a], at: CGPoint(x: 115, y: 100), tolerance: 1),
                     "point only inside the UNrotated footprint must miss")
    }

    func testHandlePositions_mapThroughTransform() {
        let a = rect90()
        let handles = handlePositions(of: a)
        // Unrotated topLeft (80,95) maps under +90° about (100,100) to (105,80).
        let tl = handles.first { $0.0 == .topLeft }!.1
        XCTAssertEqual(tl.x, 105, accuracy: 0.001)
        XCTAssertEqual(tl.y, 80, accuracy: 0.001)
    }

    func testRotateHandle_present_aboveTopCenter() {
        let a = rect90()
        let rotate = handlePositions(of: a).first { $0.0 == .rotate }
        XCTAssertNotNil(rotate)
        // Object-space rest position: (midX, minY - 24) = (100, 71); under
        // +90° about (100,100) → (129, 100).
        XCTAssertEqual(rotate!.1.x, 129, accuracy: 0.001)
        XCTAssertEqual(rotate!.1.y, 100, accuracy: 0.001)
    }

    func testRotateHandle_honorsCustomOffset() {
        var a = rect90()
        a.transform = AnnotationTransform()
        // The canvas passes a zoom-compensated offset so the lollipop keeps a
        // constant view-space gap above the object at every zoom level.
        let rotate = handlePositions(of: a, rotateOffset: 40).first { $0.0 == .rotate }!.1
        XCTAssertEqual(rotate, CGPoint(x: 100, y: 55))
        XCTAssertEqual(
            hitTestHandles(of: a, at: CGPoint(x: 100, y: 55), handleSize: 12, rotateOffset: 40),
            .rotate
        )
    }

    func testRotateHandle_verticalFlip_staysAboveTopCenter() {
        var a = rect90()
        a.transform = AnnotationTransform(rotationDegrees: 0, flipH: false, flipV: true)
        let rotate = handlePositions(of: a).first { $0.0 == .rotate }!.1
        // The lollipop tracks ROTATION only, never the flip: a vertical flip
        // must leave it above the top-center at (100, 71), NOT mirror it to the
        // bottom at (100, 129). This is what keeps "anchor straight up = 0°".
        XCTAssertEqual(rotate.x, 100, accuracy: 0.001)
        XCTAssertEqual(rotate.y, 71, accuracy: 0.001)
    }

    func testRotateHandle_rotatedAndVerticalFlip_followsRotationOnly() {
        var a = rect90()
        a.transform = AnnotationTransform(rotationDegrees: 90, flipH: false, flipV: true)
        let rotate = handlePositions(of: a).first { $0.0 == .rotate }!.1
        // Rotation-only mapping of (100,71) under +90° about (100,100) → (129,100),
        // independent of the vertical flip.
        XCTAssertEqual(rotate.x, 129, accuracy: 0.001)
        XCTAssertEqual(rotate.y, 100, accuracy: 0.001)
    }

    func testResizeHandles_stillHonorFlip_evenAsRotateHandleIgnoresIt() {
        var a = rect90()
        a.transform = AnnotationTransform(rotationDegrees: 0, flipH: false, flipV: true)
        // topLeft (80,95) under a vertical flip about (100,100) maps to (80,105):
        // the resize handles must keep tracking the mirrored object.
        let tl = handlePositions(of: a).first { $0.0 == .topLeft }!.1
        XCTAssertEqual(tl.x, 80, accuracy: 0.001)
        XCTAssertEqual(tl.y, 105, accuracy: 0.001)
    }

    func testIdentity_handlesUnchanged_butRotateHandleStillPresent() {
        var a = rect90()
        a.transform = AnnotationTransform()
        let handles = handlePositions(of: a)
        let tl = handles.first { $0.0 == .topLeft }!.1
        XCTAssertEqual(tl, CGPoint(x: 80, y: 95))
        let rotate = handles.first { $0.0 == .rotate }!.1
        XCTAssertEqual(rotate, CGPoint(x: 100, y: 71))
    }
}
