import XCTest
@testable import Sealshot

/// Dragging an endpoint after flipping a line or arrow.
///
/// Reported from the field: once flipped, dragging either end "feels flipped".
/// It was worse than that — the handle could not follow the pointer at all.
/// A stored flip mirrors about the object's OWN bounds centre, and dragging an
/// endpoint moves that centre; for a two-point shape the two cancel exactly.
/// Mirroring `end` about the midpoint of `start`/`end` lands it back on
/// `start`, wherever the cursor goes, so the rendered handle was pinned.
///
/// Point-based shapes therefore mirror their POINTS and store no flip. The
/// display is identical — a flag would mirror about the same centre — but the
/// transform is no longer in the way of the drag.
@MainActor
final class FlippedEndpointDragTests: XCTestCase {

    private func makeState() -> EditorState {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return EditorState(sourceImage: ctx.makeImage()!, sourceURL: nil)
    }

    private func addLine(_ state: EditorState, start: CGPoint, end: CGPoint,
                         arrow: Bool = false) -> UUID {
        let annotation = Annotation(
            geometry: arrow ? .arrow(start: start, end: end) : .line(start: start, end: end),
            style: Style(strokeColor: SerializableColor(NSColor.red), strokeWidth: 2))
        state.annotations.append(annotation)
        state.selectedAnnotationIDs = [annotation.id]
        return annotation.id
    }

    private func geometry(_ state: EditorState, _ id: UUID) -> Geometry {
        state.annotations.first { $0.id == id }!.geometry
    }
    private func transform(_ state: EditorState, _ id: UUID) -> AnnotationTransform {
        state.annotations.first { $0.id == id }!.transform
    }

    /// The bug, stated as the user meets it: flip, then drag an end to a new
    /// place — the end must BE at that place.
    func testDraggingAnEndAfterAHorizontalFlip_landsUnderThePointer() {
        let state = makeState()
        let id = addLine(state, start: CGPoint(x: 20, y: 100), end: CGPoint(x: 120, y: 100),
                         arrow: true)
        state.flipSelected(horizontal: true)

        let idx = state.annotations.firstIndex { $0.id == id }!
        let target = CGPoint(x: 300, y: 160)
        // What the overlay does for a drag: inverse-map through the transform,
        // then resize. With no transform stored, the point passes through.
        let t = transform(state, id)
        var dragPoint = target
        if !t.isIdentity {
            let b = geometryBounds(geometry(state, id))
            dragPoint = target.applying(
                transformMatrix(for: t, center: CGPoint(x: b.midX, y: b.midY)).inverted())
        }
        state.annotations[idx].geometry = resizeGeometry(
            geometry(state, id), handle: .end, to: dragPoint)

        guard case let .arrow(_, end) = geometry(state, id) else { return XCTFail("not an arrow") }
        // The rendered position of `end` — what the user sees the handle at.
        let b = geometryBounds(geometry(state, id))
        let rendered = end.applying(
            transformMatrix(for: transform(state, id), center: CGPoint(x: b.midX, y: b.midY)))
        XCTAssertEqual(rendered.x, target.x, accuracy: 0.001)
        XCTAssertEqual(rendered.y, target.y, accuracy: 0.001)
    }

    func testDraggingAnEndAfterAVerticalFlip_landsUnderThePointer() {
        let state = makeState()
        let id = addLine(state, start: CGPoint(x: 20, y: 40), end: CGPoint(x: 120, y: 140))
        state.flipSelected(horizontal: false)

        let idx = state.annotations.firstIndex { $0.id == id }!
        let target = CGPoint(x: 90, y: 260)
        state.annotations[idx].geometry = resizeGeometry(
            geometry(state, id), handle: .start, to: target)

        guard case let .line(start, _) = geometry(state, id) else { return XCTFail("not a line") }
        XCTAssertTrue(transform(state, id).isIdentity,
                      "a flipped line carries no transform to inverse-map")
        XCTAssertEqual(start.x, target.x, accuracy: 0.001)
        XCTAssertEqual(start.y, target.y, accuracy: 0.001)
    }

    /// The flip itself must still look the same: the points end up where the
    /// old flag would have DRAWN them.
    func testFlipMirrorsThePointsExactlyAsTheFlagWouldHaveDrawnThem() {
        let state = makeState()
        let start = CGPoint(x: 20, y: 100), end = CGPoint(x: 120, y: 60)
        let id = addLine(state, start: start, end: end, arrow: true)
        let before = geometry(state, id)
        let b = geometryBounds(before)
        let expected = AnnotationTransform(flipH: true)
        let m = transformMatrix(for: expected, center: CGPoint(x: b.midX, y: b.midY))

        state.flipSelected(horizontal: true)

        guard case let .arrow(newStart, newEnd) = geometry(state, id) else {
            return XCTFail("not an arrow")
        }
        XCTAssertEqual(newStart.x, start.applying(m).x, accuracy: 0.001)
        XCTAssertEqual(newEnd.x, end.applying(m).x, accuracy: 0.001)
        XCTAssertEqual(newStart.y, start.y, accuracy: 0.001)
        XCTAssertTrue(transform(state, id).isIdentity)
    }

    /// Flipping twice returns the original — the operation stays an involution.
    func testFlippingTwice_restoresTheOriginal() {
        let state = makeState()
        let start = CGPoint(x: 20, y: 100), end = CGPoint(x: 120, y: 60)
        let id = addLine(state, start: start, end: end)
        state.flipSelected(horizontal: true)
        state.flipSelected(horizontal: true)
        guard case let .line(s, e) = geometry(state, id) else { return XCTFail("not a line") }
        XCTAssertEqual(s.x, start.x, accuracy: 0.001)
        XCTAssertEqual(e.x, end.x, accuracy: 0.001)
    }

    /// A rotated shape still mirrors as a SCREEN mirror: the rendered points
    /// after the flip are the mirror of the rendered points before it.
    func testFlipOfARotatedLine_isStillAScreenMirror() {
        let state = makeState()
        let start = CGPoint(x: 20, y: 100), end = CGPoint(x: 120, y: 60)
        let id = addLine(state, start: start, end: end)
        let idx = state.annotations.firstIndex { $0.id == id }!
        state.annotations[idx].transform.rotationDegrees = 30

        let b = geometryBounds(geometry(state, id))
        let center = CGPoint(x: b.midX, y: b.midY)
        let renderedBefore = start.applying(
            transformMatrix(for: transform(state, id), center: center))

        state.flipSelected(horizontal: true)

        guard case let .line(s, _) = geometry(state, id) else { return XCTFail("not a line") }
        let renderedAfter = s.applying(
            transformMatrix(for: transform(state, id), center: center))
        XCTAssertEqual(renderedAfter.x, 2 * center.x - renderedBefore.x, accuracy: 0.001,
                       "mirrored about the same centre")
        XCTAssertEqual(renderedAfter.y, renderedBefore.y, accuracy: 0.001)
    }

    /// Rects keep the flag: their centre doesn't move with the edge you drag,
    /// so the flag causes no trouble there — and for an image overlay it is
    /// the only way to mirror the CONTENT.
    func testRectangleGeometry_stillFlipsViaTheTransform() {
        let state = makeState()
        let annotation = Annotation(
            geometry: .rectangle(rect: CGRect(x: 10, y: 10, width: 80, height: 40)),
            style: Style(strokeColor: SerializableColor(NSColor.red), strokeWidth: 2))
        state.annotations.append(annotation)
        state.selectedAnnotationIDs = [annotation.id]

        state.flipSelected(horizontal: true)

        XCTAssertTrue(state.annotations[0].transform.flipH)
        XCTAssertEqual(state.annotations[0].geometry,
                       .rectangle(rect: CGRect(x: 10, y: 10, width: 80, height: 40)))
    }
}
