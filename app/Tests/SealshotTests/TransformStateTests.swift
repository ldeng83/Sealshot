import XCTest
@testable import Sealshot

@MainActor
final class TransformStateTests: XCTestCase {
    private func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private func makeState(_ annotations: [Annotation]) -> EditorState {
        let s = EditorState(sourceImage: makeImage(), sourceURL: nil)
        s.annotations = annotations
        return s
    }
    private func rect() -> Annotation {
        Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
                   style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 2))
    }

    func testSetRotation_normalizesAndUndoesAsOneStep() {
        let a = rect()
        let state = makeState([a])
        let h = TimelineTestHarness(state)
        state.selectedAnnotationID = a.id
        state.setRotation(annotationID: a.id, degrees: 200)
        XCTAssertEqual(state.annotations[0].transform.rotationDegrees, -160)
        XCTAssertTrue(h.canUndo)
        h.undo()
        XCTAssertTrue(state.annotations[0].transform.isIdentity)
    }

    func testSetRotation_sameValue_noCheckpoint() {
        let a = rect()
        let state = makeState([a])
        let h = TimelineTestHarness(state)
        state.setRotation(annotationID: a.id, degrees: 0)
        XCTAssertFalse(h.canUndo)
    }

    func testFlipSelected_appliesPerMember_skippingBadge() {
        var r = rect()
        r.transform.rotationDegrees = 30
        let t = Annotation(geometry: .text(rect: CGRect(x: 0, y: 0, width: 10, height: 10), runs: []),
                           style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0))
        let b = Annotation(geometry: .badge(center: CGPoint(x: 5, y: 5), radius: 8),
                           style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0))
        let state = makeState([r, t, b])
        let h = TimelineTestHarness(state)
        state.selectedAnnotationIDs = [r.id, t.id, b.id]
        state.flipSelected(horizontal: true)
        XCTAssertTrue(state.annotations[0].transform.flipH)
        XCTAssertEqual(state.annotations[0].transform.rotationDegrees, -30)
        XCTAssertTrue(state.annotations[1].transform.flipH, "text now flips")
        XCTAssertTrue(state.annotations[2].transform.isIdentity, "badge never flips")
        h.undo()
        XCTAssertFalse(state.annotations[0].transform.flipH)
        XCTAssertFalse(state.annotations[1].transform.flipH)
    }

    func testClonedForPaste_carriesTransform() {
        var a = rect()
        a.transform = AnnotationTransform(rotationDegrees: 45, flipV: true)
        let out = clonedForPaste([a], translatedBy: CGVector(dx: 5, dy: 5))
        XCTAssertEqual(out[0].transform, a.transform)
    }
}
