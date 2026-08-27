import XCTest
@testable import Sealshot

final class AnnotationHitTestTests: XCTestCase {

    private let red = SerializableColor(r: 1, g: 0, b: 0, a: 1)

    private func arrow(start: CGPoint, end: CGPoint) -> Annotation {
        Annotation(geometry: .arrow(start: start, end: end),
                   style: Style(strokeColor: red, strokeWidth: 3))
    }

    private func rect(_ r: CGRect) -> Annotation {
        Annotation(geometry: .rectangle(rect: r),
                   style: Style(strokeColor: red, strokeWidth: 3))
    }

    // MARK: - hitTestAnnotations

    func testHitArrow_pointOnMidpoint_hits() {
        let a = arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        let id = hitTestAnnotations([a], at: CGPoint(x: 50, y: 0), tolerance: 6)
        XCTAssertEqual(id, a.id)
    }

    func testHitArrow_pointFarFromLine_misses() {
        let a = arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        let id = hitTestAnnotations([a], at: CGPoint(x: 50, y: 30), tolerance: 6)
        XCTAssertNil(id)
    }

    func testHitRectangle_pointOnEdge_hits() {
        let r = rect(CGRect(x: 0, y: 0, width: 100, height: 50))
        let id = hitTestAnnotations([r], at: CGPoint(x: 100, y: 25), tolerance: 6)
        XCTAssertEqual(id, r.id)
    }

    func testHitRectangle_pointInsideEmptyRect_misses() {
        // Rect is outlined only — inside the body shouldn't hit
        let r = rect(CGRect(x: 0, y: 0, width: 100, height: 50))
        let id = hitTestAnnotations([r], at: CGPoint(x: 50, y: 25), tolerance: 6)
        XCTAssertNil(id)
    }

    func testHitTopmostWins_lastInListWins() {
        // Last drawn is on top
        let bottom = arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        let top    = arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        let id = hitTestAnnotations([bottom, top], at: CGPoint(x: 50, y: 0), tolerance: 6)
        XCTAssertEqual(id, top.id)
    }

    // MARK: - hitTestHandles

    func testHandle_arrowStart() {
        let a = arrow(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 90))
        let handle = hitTestHandles(of: a, at: CGPoint(x: 10, y: 10), handleSize: 8)
        XCTAssertEqual(handle, .start)
    }

    func testHandle_arrowEnd() {
        let a = arrow(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 90))
        let handle = hitTestHandles(of: a, at: CGPoint(x: 90, y: 90), handleSize: 8)
        XCTAssertEqual(handle, .end)
    }

    func testHandle_rectangleTopLeft() {
        let r = rect(CGRect(x: 20, y: 30, width: 100, height: 50))
        let handle = hitTestHandles(of: r, at: CGPoint(x: 20, y: 30), handleSize: 8)
        XCTAssertEqual(handle, .topLeft)
    }

    func testHandle_rectangleBottomRight() {
        let r = rect(CGRect(x: 20, y: 30, width: 100, height: 50))
        let handle = hitTestHandles(of: r, at: CGPoint(x: 120, y: 80), handleSize: 8)
        XCTAssertEqual(handle, .bottomRight)
    }

    func testHandle_rectangleTopMidpoint() {
        let r = rect(CGRect(x: 0, y: 0, width: 100, height: 50))
        let handle = hitTestHandles(of: r, at: CGPoint(x: 50, y: 0), handleSize: 8)
        XCTAssertEqual(handle, .top)
    }

    func testHandle_farFromAnyHandle_returnsNil() {
        let r = rect(CGRect(x: 0, y: 0, width: 100, height: 50))
        let handle = hitTestHandles(of: r, at: CGPoint(x: 200, y: 200), handleSize: 8)
        XCTAssertNil(handle)
    }

    // MARK: - Fill-aware rectangle body hits

    private func filledRect(_ r: CGRect) -> Annotation {
        Annotation(geometry: .rectangle(rect: r),
                   style: Style(strokeColor: red, strokeWidth: 3, fillColor: red))
    }

    func testFilledRect_interiorPoint_hits() {
        let a = filledRect(CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(hitTestAnnotations([a], at: CGPoint(x: 50, y: 50), tolerance: 6), a.id)
    }

    func testUnfilledRect_interiorPoint_misses() {
        let a = rect(CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(hitTestAnnotations([a], at: CGPoint(x: 50, y: 50), tolerance: 6))
    }

    func testUnfilledRect_edgePoint_hits() {
        let a = rect(CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(hitTestAnnotations([a], at: CGPoint(x: 0, y: 50), tolerance: 6), a.id)
    }

    // MARK: - Marquee rect selection

    private func rectAnno(_ r: CGRect) -> Annotation {
        Annotation(geometry: .rectangle(rect: r),
                   style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3))
    }

    /// Marquee selection is CONTAINMENT, not intersection: a band swept across
    /// a busy canvas selects what it encloses, not everything it grazed.
    func testAnnotationsContained_takesEnclosedSkipsStraddling() {
        let inside  = rectAnno(CGRect(x: 10, y: 10, width: 10, height: 10))
        let straddle = rectAnno(CGRect(x: 45, y: 45, width: 20, height: 20))
        let outside = rectAnno(CGRect(x: 200, y: 200, width: 10, height: 10))
        let marquee = CGRect(x: 0, y: 0, width: 50, height: 50)
        let hits = annotationsContained([inside, straddle, outside], rect: marquee)
        XCTAssertEqual(hits, [inside.id],
                       "only the fully enclosed object is selected")
    }

    /// An object flush with the marquee edge is enclosed — `contains` is
    /// inclusive of the boundary, so dragging exactly to an object's edge
    /// still takes it rather than missing by a pixel.
    func testAnnotationsContained_flushWithEdgeIsEnclosed() {
        let flush = rectAnno(CGRect(x: 0, y: 0, width: 50, height: 50))
        let marquee = CGRect(x: 0, y: 0, width: 50, height: 50)
        XCTAssertEqual(annotationsContained([flush], rect: marquee), [flush.id])
    }

    /// An arrow is selected by its bounding box, and only when that whole box
    /// is enclosed — the diagonal poking out of the marquee is enough to skip it.
    func testAnnotationsContained_arrowByBounds() {
        let arrow = Annotation(geometry: .arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 30, y: 30)),
                               style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3))
        let grazing = CGRect(x: 20, y: 20, width: 40, height: 40)
        XCTAssertEqual(annotationsContained([arrow], rect: grazing), [],
                       "the arrow starts outside the marquee, so it is not enclosed")

        let enclosing = CGRect(x: -5, y: -5, width: 50, height: 50)
        XCTAssertEqual(annotationsContained([arrow], rect: enclosing), [arrow.id])
    }

    /// A marquee dragged up-and-left has a negative width/height before
    /// standardizing; containment must not depend on drag direction.
    func testAnnotationsContained_normalizesBackwardsDrag() {
        let inside = rectAnno(CGRect(x: 10, y: 10, width: 10, height: 10))
        let backwards = CGRect(x: 50, y: 50, width: -50, height: -50)
        XCTAssertEqual(annotationsContained([inside], rect: backwards), [inside.id])
    }

    func test_textBox_bodyIsHittableInside() {
        let text = Annotation(
            geometry: .text(rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                            runs: [TextRun(text: "hi", color: SerializableColor(r: 0, g: 0, b: 0, a: 1), fontSize: 18, isBold: false)]),
            style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 0)
        )
        XCTAssertEqual(hitTestAnnotations([text], at: CGPoint(x: 50, y: 20), tolerance: 6), text.id)
        XCTAssertNil(hitTestAnnotations([text], at: CGPoint(x: 200, y: 200), tolerance: 6))
    }

    func test_textBox_hasEightHandles() {
        let t = Annotation(
            geometry: .text(rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                            runs: [TextRun(text: "hi", color: SerializableColor(r: 0, g: 0, b: 0, a: 1), fontSize: 18, isBold: false)]),
            style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 0))
        XCTAssertEqual(hitTestHandles(of: t, at: CGPoint(x: 50, y: 0), handleSize: 8), .top)
        XCTAssertEqual(hitTestHandles(of: t, at: CGPoint(x: 50, y: 40), handleSize: 8), .bottom)
        XCTAssertEqual(hitTestHandles(of: t, at: CGPoint(x: 0, y: 0), handleSize: 8), .topLeft)
    }

    func test_textBoxHeightFloor_clampsToContent() {
        let runs = [TextRun(text: "one two three four five six seven", color: SerializableColor(r: 0, g: 0, b: 0, a: 1), fontSize: 18, isBold: false)]
        let content = textBoxHeight(runs: runs, width: 80)
        let clamped = clampTextHeight(rect: CGRect(x: 0, y: 0, width: 80, height: 5),
                                      runs: runs, anchorBottom: false)
        XCTAssertEqual(clamped.height, content, accuracy: 0.5)
        XCTAssertEqual(clamped.minY, 0, accuracy: 0.01)
    }

    func test_textBoxHeightFloor_allowsTaller() {
        let runs = [TextRun(text: "x", color: SerializableColor(r: 0, g: 0, b: 0, a: 1), fontSize: 18, isBold: false)]
        let tall = clampTextHeight(rect: CGRect(x: 0, y: 0, width: 80, height: 500),
                                   runs: runs, anchorBottom: false)
        XCTAssertEqual(tall.height, 500, accuracy: 0.01)
    }

    func test_textBoxHeightFloor_anchorBottomGrowsUp() {
        let runs = [TextRun(text: "one two three four five six seven", color: SerializableColor(r: 0, g: 0, b: 0, a: 1), fontSize: 18, isBold: false)]
        let content = textBoxHeight(runs: runs, width: 80)
        // A short box at y=100..105; anchoring the bottom (maxY=105) should grow upward.
        let clamped = clampTextHeight(rect: CGRect(x: 0, y: 100, width: 80, height: 5),
                                      runs: runs, anchorBottom: true)
        XCTAssertEqual(clamped.height, content, accuracy: 0.5)
        XCTAssertEqual(clamped.maxY, 105, accuracy: 0.01)   // bottom edge stays fixed
    }

    func test_ellipse_filledHitInsideNotCorner() {
        let e = Annotation(
            geometry: .ellipse(rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
            style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 3,
                         fillColor: SerializableColor(r: 1, g: 0, b: 0, a: 1)))
        XCTAssertEqual(hitTestAnnotations([e], at: CGPoint(x: 50, y: 50), tolerance: 4), e.id) // center
        XCTAssertNil(hitTestAnnotations([e], at: CGPoint(x: 2, y: 2), tolerance: 4))           // corner outside oval
    }
    func test_ellipse_eightHandles() {
        let e = Annotation(
            geometry: .ellipse(rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
            style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 3))
        XCTAssertEqual(hitTestHandles(of: e, at: CGPoint(x: 0, y: 0), handleSize: 8), .topLeft)
        XCTAssertEqual(hitTestHandles(of: e, at: CGPoint(x: 50, y: 0), handleSize: 8), .top)
    }

    func test_ellipse_outlineHitsEdgeNotCenter() {
        // Outline-only ellipse (no fill): a point ON the boundary hits; the
        // hollow center misses.
        let e = Annotation(
            geometry: .ellipse(rect: CGRect(x: 0, y: 0, width: 100, height: 60)),
            style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 3,
                         fillColor: nil))
        // Right vertex of the ellipse is at (100, 30) — on the boundary.
        XCTAssertEqual(hitTestAnnotations([e], at: CGPoint(x: 100, y: 30), tolerance: 4), e.id)
        // Center is hollow for an outline-only ellipse.
        XCTAssertNil(hitTestAnnotations([e], at: CGPoint(x: 50, y: 30), tolerance: 4))
    }

    func test_line_hitsNearSegment() {
        let l = Annotation(
            geometry: .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)),
            style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 3))
        XCTAssertEqual(hitTestAnnotations([l], at: CGPoint(x: 50, y: 2), tolerance: 6), l.id)
        XCTAssertNil(hitTestAnnotations([l], at: CGPoint(x: 50, y: 40), tolerance: 6))
    }
    func test_line_twoHandles() {
        let l = Annotation(
            geometry: .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)),
            style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 3))
        XCTAssertEqual(hitTestHandles(of: l, at: CGPoint(x: 0, y: 0), handleSize: 8), .start)
        XCTAssertEqual(hitTestHandles(of: l, at: CGPoint(x: 100, y: 0), handleSize: 8), .end)
    }
    func test_badge_hitWithinRadius() {
        let b = Annotation(geometry: .badge(center: CGPoint(x: 50, y: 50), radius: 20),
                           style: Style(strokeColor: SerializableColor(r: 1, g: 1, b: 1, a: 1), strokeWidth: 0))
        XCTAssertEqual(hitTestAnnotations([b], at: CGPoint(x: 55, y: 55), tolerance: 4), b.id)
        XCTAssertNil(hitTestAnnotations([b], at: CGPoint(x: 100, y: 100), tolerance: 4))
    }
    func test_badge_fourHandles() {
        let b = Annotation(geometry: .badge(center: CGPoint(x: 50, y: 50), radius: 20),
                           style: Style(strokeColor: SerializableColor(r: 1, g: 1, b: 1, a: 1), strokeWidth: 0))
        XCTAssertEqual(hitTestHandles(of: b, at: CGPoint(x: 50, y: 30), handleSize: 8), .top)
        XCTAssertEqual(hitTestHandles(of: b, at: CGPoint(x: 70, y: 50), handleSize: 8), .right)
    }
}
