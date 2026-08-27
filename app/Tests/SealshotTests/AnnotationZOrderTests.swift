import XCTest
@testable import Sealshot

@MainActor
final class AnnotationZOrderTests: XCTestCase {

    private func note(_ x: CGFloat) -> Annotation {
        Annotation(geometry: .rectangle(rect: CGRect(x: x, y: 0, width: 10, height: 10)),
                   style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 2))
    }
    private func ids(_ a: [Annotation]) -> [UUID] { a.map(\.id) }

    func testToFront_movesGroupToEnd_preservingGroupOrder() {
        let a = note(0), s1 = note(1), b = note(2), s2 = note(3), c = note(4)
        let out = reorderAnnotations([a, s1, b, s2, c],
                                     selected: [s1.id, s2.id], .toFront)
        XCTAssertEqual(ids(out), ids([a, b, c, s1, s2]))
    }

    func testToBack_movesGroupToStart() {
        let a = note(0), s = note(1), b = note(2)
        let out = reorderAnnotations([a, s, b], selected: [s.id], .toBack)
        XCTAssertEqual(ids(out), ids([s, a, b]))
    }

    func testForward_movesPastNearestUpperNeighbor() {
        let a = note(0), s = note(1), b = note(2), c = note(3)
        let out = reorderAnnotations([a, s, b, c], selected: [s.id], .forward)
        XCTAssertEqual(ids(out), ids([a, b, s, c]))
    }

    func testBackward_movesPastNearestLowerNeighbor() {
        let a = note(0), b = note(1), s = note(2), c = note(3)
        let out = reorderAnnotations([a, b, s, c], selected: [s.id], .backward)
        XCTAssertEqual(ids(out), ids([a, s, b, c]))
    }

    func testForward_atFront_isNoOp() {
        let a = note(0), s = note(1)
        let input = [a, s]
        XCTAssertEqual(ids(reorderAnnotations(input, selected: [s.id], .forward)),
                       ids(input))
    }

    func testBackward_atBack_isNoOp() {
        let s = note(0), a = note(1)
        let input = [s, a]
        XCTAssertEqual(ids(reorderAnnotations(input, selected: [s.id], .backward)),
                       ids(input))
    }

    func testEmptySelection_isNoOp() {
        let a = note(0), b = note(1)
        XCTAssertEqual(ids(reorderAnnotations([a, b], selected: [], .toFront)),
                       ids([a, b]))
    }

    // MARK: EditorState integration

    private func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testReorderSelected_oneUndoStep() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let h = TimelineTestHarness(state)
        let bottom = note(0), top = note(1)
        state.annotations = [bottom, top]
        state.selectedAnnotationID = bottom.id

        state.reorderSelected(.toFront)
        XCTAssertEqual(ids(state.annotations), ids([top, bottom]))
        XCTAssertTrue(h.canUndo)
        h.undo()
        XCTAssertEqual(ids(state.annotations), ids([bottom, top]))
    }

    func testReorderSelected_noOpRecordsNoCheckpoint() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let h = TimelineTestHarness(state)
        let bottom = note(0), top = note(1)
        state.annotations = [bottom, top]
        state.selectedAnnotationID = top.id

        state.reorderSelected(.toFront)   // already frontmost
        XCTAssertFalse(h.canUndo, "no-op must not burn an undo step")
    }
}
