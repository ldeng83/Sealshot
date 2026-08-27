import XCTest
@testable import Sealshot

final class AnnotationTransformTests: XCTestCase {

    func testNormalizedDegrees_wrapsIntoRange() {
        XCTAssertEqual(normalizedDegrees(0), 0)
        XCTAssertEqual(normalizedDegrees(179), 179)
        XCTAssertEqual(normalizedDegrees(180), -180)   // 180 wraps to -180
        XCTAssertEqual(normalizedDegrees(-180), -180)  // -180 is in range
        XCTAssertEqual(normalizedDegrees(360), 0)
        XCTAssertEqual(normalizedDegrees(-541), 179)
        XCTAssertEqual(normalizedDegrees(721), 1)
    }

    func testIdentity() {
        XCTAssertTrue(AnnotationTransform().isIdentity)
        XCTAssertFalse(AnnotationTransform(rotationDegrees: 1).isIdentity)
        XCTAssertFalse(AnnotationTransform(flipH: true).isIdentity)
    }

    func testFlippedH_negatesAngle() {
        let t = AnnotationTransform(rotationDegrees: 30).flippedH()
        XCTAssertTrue(t.flipH)
        XCTAssertEqual(t.rotationDegrees, -30)
    }

    func testFlippedV_negatesAngle() {
        let t = AnnotationTransform(rotationDegrees: 30).flippedV()
        XCTAssertTrue(t.flipV)
        XCTAssertEqual(t.rotationDegrees, -30)
        let t2 = AnnotationTransform(rotationDegrees: -170).flippedV()
        XCTAssertEqual(t2.rotationDegrees, 170)
    }

    func testDoubleFlip_returnsToUnflipped() {
        let t = AnnotationTransform(rotationDegrees: 30).flippedH().flippedH()
        XCTAssertFalse(t.flipH)
        XCTAssertEqual(t.rotationDegrees, 30)
        let v = AnnotationTransform(rotationDegrees: 30).flippedV().flippedV()
        XCTAssertFalse(v.flipV)
        XCTAssertEqual(v.rotationDegrees, 30)
    }

    /// Pin the SCREEN-SPACE effect of the UI flips, not just the stored
    /// flags: flippedV must mirror displayed points top-bottom about the
    /// center, and must differ from flippedH. (A flag-only test let a
    /// 180−θ formula through that rendered Flip Vertical as a horizontal
    /// mirror.)
    func testFlippedV_pointMapping_isVerticalMirrorOfDisplay() {
        let center = CGPoint(x: 5, y: 2.5)
        let probe = CGPoint(x: 8, y: 1)   // off both axes so H ≠ V
        for start in [AnnotationTransform(),
                      AnnotationTransform(rotationDegrees: 30),
                      AnnotationTransform(rotationDegrees: -75, flipH: true)] {
            let displayed = probe.applying(transformMatrix(for: start, center: center))
            let mirroredV = CGPoint(x: displayed.x, y: 2 * center.y - displayed.y)
            let mirroredH = CGPoint(x: 2 * center.x - displayed.x, y: displayed.y)
            let afterV = probe.applying(transformMatrix(for: start.flippedV(), center: center))
            let afterH = probe.applying(transformMatrix(for: start.flippedH(), center: center))
            XCTAssertEqual(afterV.x, mirroredV.x, accuracy: 1e-9)
            XCTAssertEqual(afterV.y, mirroredV.y, accuracy: 1e-9)
            XCTAssertEqual(afterH.x, mirroredH.x, accuracy: 1e-9)
            XCTAssertEqual(afterH.y, mirroredH.y, accuracy: 1e-9)
        }
    }

    // MARK: codec

    func testAnnotation_transformRoundTrips() throws {
        var a = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
                           style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 2))
        a.transform = AnnotationTransform(rotationDegrees: 45, flipH: true)
        let data = try encodeAnnotations([a], crop: nil, focus: nil)
        let back = try decodeAnnotations(from: data)
        XCTAssertEqual(back.annotations.first?.transform,
                       AnnotationTransform(rotationDegrees: 45, flipH: true))
    }

    func testAnnotation_missingTransformKey_decodesToIdentity() throws {
        // v5-era annotation JSON (no "transform" key) must decode as identity.
        let a = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 5, height: 5)),
                           style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 2))
        var obj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(a)) as! [String: Any]
        obj.removeValue(forKey: "transform")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(Annotation.self, from: stripped)
        XCTAssertTrue(back.transform.isIdentity)
    }

    func testEnvelope_writesVersion12_andDecodes5() throws {
        let data = try encodeAnnotations([], crop: nil, focus: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["version"] as? Int, 12)   // v11 contentClip, v12 textLayoutWidth
        let v5 = """
        {"version":5,"annotations":[],"croppedRect":null,"focusRect":null}
        """.data(using: .utf8)!
        XCTAssertNoThrow(try decodeAnnotations(from: v5))
    }
}
