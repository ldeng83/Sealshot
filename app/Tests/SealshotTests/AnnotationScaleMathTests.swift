import XCTest
@testable import Sealshot

final class AnnotationScaleMathTests: XCTestCase {

    private func style(stroke: CGFloat = 4, font: CGFloat = 16, corner: CGFloat = 6) -> Style {
        var s = Style(strokeColor: SerializableColor(.red), strokeWidth: stroke)
        s.fontSize = font
        s.cornerRadius = corner
        return s
    }

    func test_uniformScale_pointsRectsAndSizes() {
        let annotations = [
            Annotation(geometry: .arrow(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 110, y: 220)),
                       style: style()),
            Annotation(geometry: .rectangle(rect: CGRect(x: 40, y: 60, width: 200, height: 100)),
                       style: style()),
            Annotation(geometry: .badge(center: CGPoint(x: 50, y: 50), radius: 14), style: style()),
            Annotation(geometry: .pen(points: [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 6)]),
                       style: style()),
        ]
        let out = AnnotationScaleMath.scaledAnnotations(annotations, fx: 0.5, fy: 0.5)

        guard case .arrow(let s, let e) = out[0].geometry else { return XCTFail() }
        XCTAssertEqual(s, CGPoint(x: 5, y: 10)); XCTAssertEqual(e, CGPoint(x: 55, y: 110))
        guard case .rectangle(let r) = out[1].geometry else { return XCTFail() }
        XCTAssertEqual(r, CGRect(x: 20, y: 30, width: 100, height: 50))
        guard case .badge(let c, let radius) = out[2].geometry else { return XCTFail() }
        XCTAssertEqual(c, CGPoint(x: 25, y: 25)); XCTAssertEqual(radius, 7)
        guard case .pen(let pts) = out[3].geometry else { return XCTFail() }
        XCTAssertEqual(pts[1], CGPoint(x: 4, y: 3))
        XCTAssertEqual(out[0].style.strokeWidth, 2)
        XCTAssertEqual(out[0].style.fontSize, 8)
        XCTAssertEqual(out[0].style.cornerRadius, 3)
    }

    func test_textRuns_fontSizesScale() {
        let runs = [TextRun(text: "Hi", color: .init(NSColor.white), fontSize: 20, isBold: false),
                    TextRun(text: "there", color: .init(NSColor.white), fontSize: 12, isBold: true)]
        let a = Annotation(geometry: .text(rect: CGRect(x: 0, y: 0, width: 100, height: 40), runs: runs),
                           style: style())
        let out = AnnotationScaleMath.scaledAnnotations([a], fx: 2, fy: 2)[0]
        guard case .text(let rect, let outRuns) = out.geometry else { return XCTFail() }
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 200, height: 80))
        XCTAssertEqual(outRuns.map(\.fontSize), [40, 24])
        XCTAssertEqual(outRuns.map(\.text), ["Hi", "there"], "content untouched")
    }

    func test_blurRegions_allShapes() {
        let cases: [BlurRegion] = [
            .rect(CGRect(x: 10, y: 10, width: 40, height: 20)),
            .ellipse(CGRect(x: 10, y: 10, width: 40, height: 20)),
            .freehand(points: [CGPoint(x: 4, y: 8)], width: 10),
        ]
        let out = cases.map { AnnotationScaleMath.scaledBlur($0, fx: 0.5, fy: 0.5) }
        XCTAssertEqual(out[0], .rect(CGRect(x: 5, y: 5, width: 20, height: 10)))
        XCTAssertEqual(out[1], .ellipse(CGRect(x: 5, y: 5, width: 20, height: 10)))
        guard case .freehand(let pts, let w) = out[2] else { return XCTFail() }
        XCTAssertEqual(pts, [CGPoint(x: 2, y: 4)]); XCTAssertEqual(w, 5)
    }

    func test_nonUniformScale_sizesUseGeometricMean() {
        // fx=4, fy=1 → 1-D sizes scale by √4 = 2.
        let a = Annotation(geometry: .badge(center: .zero, radius: 10), style: style(stroke: 3))
        let out = AnnotationScaleMath.scaledAnnotations([a], fx: 4, fy: 1)[0]
        guard case .badge(_, let radius) = out.geometry else { return XCTFail() }
        XCTAssertEqual(radius, 20)
        XCTAssertEqual(out.style.strokeWidth, 6)
    }

    func test_transformUntouched_identityRoundTrip() {
        var a = Annotation(geometry: .ellipse(rect: CGRect(x: 8, y: 8, width: 30, height: 20)),
                           style: style())
        a.transform = AnnotationTransform(rotationDegrees: 30, flipH: true, flipV: false)
        let down = AnnotationScaleMath.scaledAnnotations([a], fx: 0.5, fy: 0.5)
        let back = AnnotationScaleMath.scaledAnnotations(down, fx: 2, fy: 2)[0]
        XCTAssertEqual(back.transform, a.transform, "rotation/flips never rewritten")
        XCTAssertEqual(back.geometry, a.geometry, "scale round-trips")
        XCTAssertEqual(back.id, a.id, "identity preserved")
    }
}
