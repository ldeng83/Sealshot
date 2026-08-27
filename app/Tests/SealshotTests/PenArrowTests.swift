import XCTest
@testable import Sealshot

/// The free-draw arrow (`.penArrow`): a freehand stroke that honors the arrow
/// caps. These cover the pure units — tool mapping, the Arrow tool group,
/// geometry math that must preserve the case, and codec round-trip.
final class PenArrowTests: XCTestCase {

    private let arrowGroup = EditorToolbarBuilder.arrowGroup

    func test_geometryTool_mapsPenArrowToTool() {
        XCTAssertEqual(geometryTool(.penArrow(points: [])), .penArrow)
    }

    // MARK: Arrow tool group (chevron dropdown + remembered last pick)

    func test_arrowGroup_membershipAndDefault() {
        XCTAssertTrue(arrowGroup.contains(.arrow))
        XCTAssertTrue(arrowGroup.contains(.penArrow))
        XCTAssertEqual(arrowGroup.defaultTool, .arrow)
    }

    func test_arrowGroup_remembersFreeArrow() {
        let defaults = UserDefaults(suiteName: "penarrow-\(UUID().uuidString)")!
        XCTAssertEqual(ToolGroupPreference.last(arrowGroup, defaults), .arrow)   // unset → default
        ToolGroupPreference.store(.penArrow, in: arrowGroup, defaults)
        XCTAssertEqual(ToolGroupPreference.last(arrowGroup, defaults), .penArrow)
    }

    // MARK: Geometry math must preserve the .penArrow case (not degrade to .pen)

    func test_translate_preservesPenArrowCase() {
        let g = translatedGeometry(
            .penArrow(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]),
            by: CGVector(dx: 5, dy: 2))
        guard case let .penArrow(pts) = g else { return XCTFail("case not preserved") }
        XCTAssertEqual(pts, [CGPoint(x: 5, y: 2), CGPoint(x: 15, y: 2)])
    }

    func test_scale_preservesPenArrowCase() {
        let g = AnnotationScaleMath.scaledGeometry(
            .penArrow(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]), fx: 2, fy: 2)
        guard case let .penArrow(pts) = g else { return XCTFail("case not preserved") }
        XCTAssertEqual(pts, [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 20)])
    }

    func test_bounds_penArrowMatchesPen() {
        let pts = [CGPoint(x: 1, y: 2), CGPoint(x: 9, y: 20)]
        XCTAssertEqual(geometryBounds(.penArrow(points: pts)), geometryBounds(.pen(points: pts)))
    }

    // MARK: Head orientation — tangent of the RENDERED (smoothed) curve

    private func angle(_ v: CGVector) -> CGFloat { atan2(v.dy, v.dx) }

    func test_endpointTangents_straightStroke() throws {
        // Horizontal stroke left→right: end head points +x (~0), start head
        // points outward −x (~±π).
        let pts = (0...20).map { CGPoint(x: CGFloat($0) * 5, y: 0) }
        let (start, end) = PenPath.endpointTangents(pts, lookback: 20)
        XCTAssertEqual(angle(try XCTUnwrap(end)), 0, accuracy: 0.05)
        XCTAssertEqual(abs(angle(try XCTUnwrap(start))), .pi, accuracy: 0.05)
    }

    func test_endpointTangents_followCurveDirection() throws {
        // Quarter-turn: starts heading right (+x), ends heading down (+y, since y
        // grows downward here). Both heads follow the curve at their own ends.
        let pts: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 2), CGPoint(x: 38, y: 10),
            CGPoint(x: 52, y: 26), CGPoint(x: 60, y: 48), CGPoint(x: 62, y: 72),
        ]
        let (start, endOpt) = PenPath.endpointTangents(pts, lookback: 20)
        let end = try XCTUnwrap(endOpt)
        XCTAssertGreaterThan(angle(end), 0.6)       // heading mostly downward
        XCTAssertGreaterThan(end.dy, abs(end.dx))   // more vertical than horizontal
        // Start heads right (+x), so its OUTWARD tangent points left (−x).
        let s = try XCTUnwrap(start)
        XCTAssertLessThan(s.dx, 0)
        XCTAssertGreaterThan(abs(s.dx), abs(s.dy))  // more horizontal than vertical
    }

    func test_endpointTangents_denseStartStaysStable() throws {
        // A drag samples densely (and jitters) at the start before moving off.
        // The start head must still read the overall stroke direction, not the
        // tiny first micro-segments — this is the real-stroke failure case.
        var pts: [CGPoint] = []
        for i in 0..<8 { pts.append(CGPoint(x: CGFloat(i) * 0.4, y: (i % 2 == 0 ? 0.5 : -0.5))) } // dense jitter
        for i in 1...20 { pts.append(CGPoint(x: CGFloat(i) * 6, y: 0)) }   // then straight right
        let start = try XCTUnwrap(PenPath.endpointTangents(pts, lookback: 20).start)
        XCTAssertEqual(abs(angle(start)), .pi, accuracy: 0.3)   // outward ≈ left, not vertical
    }

    func test_endpointTangents_shortStroke() throws {
        let (start, end) = PenPath.endpointTangents(
            [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)], lookback: 20)
        XCTAssertEqual(angle(try XCTUnwrap(end)), 0, accuracy: 0.05)          // →
        XCTAssertEqual(abs(angle(try XCTUnwrap(start))), .pi, accuracy: 0.05) // ←
    }

    // MARK: Persistence — round-trips through the v10 envelope with its caps

    func test_codec_roundTrip_penArrowWithCaps() throws {
        let ann = Annotation(
            geometry: .penArrow(points: [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5), CGPoint(x: 12, y: 3)]),
            style: Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1), strokeWidth: 4,
                         startCap: .none, endCap: .filled))
        let data = try encodeAnnotations([ann], crop: nil)
        let decoded = try decodeAnnotations(from: data)

        XCTAssertEqual(decoded.annotations.count, 1)
        guard case let .penArrow(pts) = decoded.annotations[0].geometry else {
            return XCTFail("penArrow geometry not preserved through the codec")
        }
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(decoded.annotations[0].style.startCap, .none)
        XCTAssertEqual(decoded.annotations[0].style.endCap, .filled)
    }
}
