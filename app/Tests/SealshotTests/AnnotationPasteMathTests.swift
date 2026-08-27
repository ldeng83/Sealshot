import XCTest
import CoreGraphics
@testable import Sealshot

final class AnnotationPasteMathTests: XCTestCase {

    private func rectAnnotation(_ r: CGRect) -> Annotation {
        Annotation(geometry: .rectangle(rect: r),
                   style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3))
    }

    func testBoundingBox_unionsAllGeometry() {
        let a = rectAnnotation(CGRect(x: 0, y: 0, width: 10, height: 10))
        let b = rectAnnotation(CGRect(x: 20, y: 30, width: 10, height: 10))
        let box = boundingBox(of: [a, b])
        XCTAssertEqual(box, CGRect(x: 0, y: 0, width: 30, height: 40))
    }

    func testBoundingBox_emptyIsNil() {
        XCTAssertNil(boundingBox(of: []))
    }

    func testGeometryBounds_arrowNormalizes() {
        let g = Geometry.arrow(start: CGPoint(x: 30, y: 40), end: CGPoint(x: 10, y: 20))
        XCTAssertEqual(geometryBounds(g), CGRect(x: 10, y: 20, width: 20, height: 20))
    }

    func testPasteTranslation_cursorInside_centersGroupOnCursor() {
        let box = CGRect(x: 0, y: 0, width: 20, height: 20)   // center (10,10)
        let delta = pasteTranslation(boundingBox: box,
                                     cursor: CGPoint(x: 100, y: 50),
                                     imageSize: CGSize(width: 200, height: 200))
        XCTAssertEqual(delta.dx, 90, accuracy: 0.001)
        XCTAssertEqual(delta.dy, 40, accuracy: 0.001)
    }

    func testPasteTranslation_cursorOutside_centersInImage() {
        let box = CGRect(x: 0, y: 0, width: 20, height: 20)   // center (10,10)
        let delta = pasteTranslation(boundingBox: box,
                                     cursor: CGPoint(x: -5, y: 500),
                                     imageSize: CGSize(width: 200, height: 100))
        XCTAssertEqual(delta.dx, 90, accuracy: 0.001)   // 100 - 10
        XCTAssertEqual(delta.dy, 40, accuracy: 0.001)   //  50 - 10
    }

    func testPasteTranslation_nilCursor_centersInImage() {
        let box = CGRect(x: 0, y: 0, width: 20, height: 20)
        let delta = pasteTranslation(boundingBox: box, cursor: nil,
                                     imageSize: CGSize(width: 200, height: 100))
        XCTAssertEqual(delta.dx, 90, accuracy: 0.001)
        XCTAssertEqual(delta.dy, 40, accuracy: 0.001)
    }

    func testClonedForPaste_freshIdsTranslatedGeometryPreservedStyle() {
        let src = rectAnnotation(CGRect(x: 0, y: 0, width: 10, height: 10))
        let cloned = clonedForPaste([src], translatedBy: CGVector(dx: 5, dy: 7))
        XCTAssertEqual(cloned.count, 1)
        XCTAssertNotEqual(cloned[0].id, src.id)
        XCTAssertEqual(cloned[0].style, src.style)
        if case let .rectangle(r) = cloned[0].geometry {
            XCTAssertEqual(r, CGRect(x: 5, y: 7, width: 10, height: 10))
        } else { XCTFail("expected rectangle") }
    }

    private func textRuns(_ s: String) -> [TextRun] {
        [TextRun(text: s, color: SerializableColor(r: 0, g: 0, b: 0, a: 1), fontSize: 18, isBold: false)]
    }

    func test_geometryBounds_text() {
        let g = Geometry.text(rect: CGRect(x: 5, y: 8, width: 100, height: 30), runs: textRuns("hi"))
        XCTAssertEqual(geometryBounds(g), CGRect(x: 5, y: 8, width: 100, height: 30))
    }

    func test_translatedGeometry_text() {
        let g = Geometry.text(rect: CGRect(x: 5, y: 8, width: 100, height: 30), runs: textRuns("hi"))
        let moved = translatedGeometry(g, by: CGVector(dx: 10, dy: -3))
        guard case let .text(rect, runs) = moved else { return XCTFail("expected text") }
        XCTAssertEqual(rect, CGRect(x: 15, y: 5, width: 100, height: 30))
        XCTAssertEqual(runs.map { $0.text }.joined(), "hi")
    }

    func test_geometryBounds_ellipse() {
        let g = Geometry.ellipse(rect: CGRect(x: 5, y: 8, width: 100, height: 30))
        XCTAssertEqual(geometryBounds(g), CGRect(x: 5, y: 8, width: 100, height: 30))
    }
    func test_translatedGeometry_ellipse() {
        let moved = translatedGeometry(.ellipse(rect: CGRect(x: 5, y: 8, width: 10, height: 10)),
                                       by: CGVector(dx: 3, dy: -2))
        guard case let .ellipse(rect) = moved else { return XCTFail("expected ellipse") }
        XCTAssertEqual(rect, CGRect(x: 8, y: 6, width: 10, height: 10))
    }

    func test_geometryBounds_line() {
        let g = Geometry.line(start: CGPoint(x: 10, y: 5), end: CGPoint(x: 2, y: 25))
        XCTAssertEqual(geometryBounds(g), CGRect(x: 2, y: 5, width: 8, height: 20))
    }
    func test_translatedGeometry_line() {
        let moved = translatedGeometry(.line(start: .zero, end: CGPoint(x: 10, y: 10)),
                                       by: CGVector(dx: 5, dy: 5))
        guard case let .line(s, e) = moved else { return XCTFail("expected line") }
        XCTAssertEqual(s, CGPoint(x: 5, y: 5)); XCTAssertEqual(e, CGPoint(x: 15, y: 15))
    }
    func test_geometryBounds_badge() {
        let g = Geometry.badge(center: CGPoint(x: 50, y: 50), radius: 10)
        XCTAssertEqual(geometryBounds(g), CGRect(x: 40, y: 40, width: 20, height: 20))
    }
    func test_translatedGeometry_badge() {
        let moved = translatedGeometry(.badge(center: CGPoint(x: 50, y: 50), radius: 10),
                                       by: CGVector(dx: 5, dy: -5))
        guard case let .badge(center, radius) = moved else { return XCTFail("expected badge") }
        XCTAssertEqual(center, CGPoint(x: 55, y: 45)); XCTAssertEqual(radius, 10)
    }
}
