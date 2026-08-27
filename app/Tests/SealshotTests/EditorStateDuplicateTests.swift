import XCTest
import AppKit
@testable import Sealshot

/// Duplicate clones the selection in place on the canvas. It deliberately does
/// NOT touch the clipboard — ⌘D must never cost the user what they copied
/// earlier, which is why it can't be implemented as copy-then-paste.
@MainActor
final class EditorStateDuplicateTests: XCTestCase {

    private func makeImage(width: Int = 100, height: Int = 100) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makeState() -> EditorState {
        EditorState(sourceImage: makeImage(), sourceURL: nil)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat) -> Annotation {
        Annotation(id: UUID(),
                   geometry: .rectangle(rect: CGRect(x: x, y: y, width: 40, height: 30)),
                   style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3))
    }

    private func bounds(_ a: Annotation) -> CGRect {
        guard case let .rectangle(r) = a.geometry else { return .zero }
        return r
    }

    func testClonesGetFreshIdsAndKeepTheOriginals() {
        let state = makeState()
        let original = rect(10, 10)
        state.annotations = [original]
        state.setSelection([original.id], primary: original.id)

        state.duplicateSelected()

        XCTAssertEqual(state.annotations.count, 2)
        XCTAssertEqual(state.annotations[0].id, original.id, "the original is untouched")
        XCTAssertNotEqual(state.annotations[1].id, original.id, "the clone is a new object")
    }

    func testCloneIsOffsetFromTheOriginal() {
        let state = makeState()
        let original = rect(10, 10)
        state.annotations = [original]
        state.setSelection([original.id], primary: original.id)

        state.duplicateSelected()

        let clone = bounds(state.annotations[1])
        XCTAssertEqual(clone.origin.x, 10 + EditorState.duplicateOffset.dx, accuracy: 0.001)
        XCTAssertEqual(clone.origin.y, 10 + EditorState.duplicateOffset.dy, accuracy: 0.001)
    }

    func testSelectionMovesToTheClone() {
        let state = makeState()
        let original = rect(10, 10)
        state.annotations = [original]
        state.setSelection([original.id], primary: original.id)

        state.duplicateSelected()

        let cloneID = state.annotations[1].id
        XCTAssertEqual(state.selectedAnnotationIDs, [cloneID])
        XCTAssertEqual(state.primarySelectionID, cloneID, "a single clone is the primary")
    }

    func testDuplicatingAGroupSelectsAllClonesWithNoPrimary() {
        let state = makeState()
        let a = rect(10, 10), b = rect(100, 100)
        state.annotations = [a, b]
        state.setSelection([a.id, b.id], primary: nil)

        state.duplicateSelected()

        XCTAssertEqual(state.annotations.count, 4)
        XCTAssertEqual(state.selectedAnnotationIDs.count, 2)
        XCTAssertFalse(state.selectedAnnotationIDs.contains(a.id))
        XCTAssertNil(state.primarySelectionID, "a duplicated group has no primary")
    }

    /// The whole reason duplicate isn't copy-then-paste internally.
    func testClipboardIsNotTouched() {
        let state = makeState()
        let original = rect(10, 10)
        state.annotations = [original]
        state.setSelection([original.id], primary: original.id)
        let sentinel = AnnotationClipboardPayload(annotations: [rect(999, 999)], assets: [:])
        AnnotationPasteboard.write(sentinel)

        state.duplicateSelected()

        let after = AnnotationPasteboard.read()
        XCTAssertEqual(after?.annotations.count, 1)
        XCTAssertEqual(after?.annotations.first?.id, sentinel.annotations.first?.id,
                       "duplicate must leave the clipboard exactly as it found it")
    }

    /// The asset dictionary is per-document, so a duplicated image reuses the
    /// same bitmap rather than growing the saved file.
    func testDuplicatedImageSharesTheAsset() {
        let state = makeState()
        let assetID = "asset-1"
        state.registerImageAsset(id: assetID, data: Data("png".utf8))
        let image = Annotation(id: UUID(),
                               geometry: .image(rect: CGRect(x: 5, y: 5, width: 50, height: 50),
                                                assetID: assetID),
                               style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3))
        state.annotations = [image]
        state.setSelection([image.id], primary: image.id)

        state.duplicateSelected()

        guard case let .image(_, cloneAsset) = state.annotations[1].geometry else {
            return XCTFail("expected an image clone, got \(state.annotations[1].geometry)")
        }
        XCTAssertEqual(cloneAsset, assetID)
        XCTAssertEqual(state.imageAssets.count, 1, "no bitmap is copied")
    }

    func testNoOpWhenNothingIsSelected() {
        let state = makeState()
        state.annotations = [rect(10, 10)]
        state.setSelection([], primary: nil)

        state.duplicateSelected()

        XCTAssertEqual(state.annotations.count, 1)
    }

    func testNoOpWhenReadOnly() {
        let state = makeState()
        let original = rect(10, 10)
        state.annotations = [original]
        state.setSelection([original.id], primary: original.id)
        state.isReadOnly = true

        state.duplicateSelected()

        XCTAssertEqual(state.annotations.count, 1)
    }

    /// ⌘D routes through the same model call as the menu item, so a duplicate
    /// made from the keyboard is indistinguishable from a menu one.
    func testRepeatedDuplicatesEachOffsetFromTheLastClone() {
        let state = makeState()
        let original = rect(10, 10)
        state.annotations = [original]
        state.setSelection([original.id], primary: original.id)

        state.duplicateSelected()
        state.duplicateSelected()

        XCTAssertEqual(state.annotations.count, 3)
        let second = bounds(state.annotations[2])
        XCTAssertEqual(second.origin.x, 10 + EditorState.duplicateOffset.dx * 2, accuracy: 0.001,
                       "the second duplicate steps off the first, not the original")
    }

    /// The undo label is user-visible ("Undo Duplicate" in the Edit menu) and
    /// `insertPasted`'s `undoAction` parameter is defaulted — a future
    /// refactor could silently drop the override without this test catching it.
    func testDuplicateRecordsAnUndoCheckpointLabeledDuplicate() {
        let state = makeState()
        let original = rect(10, 10)
        state.annotations = [original]
        state.setSelection([original.id], primary: original.id)
        var received: EditorSnapshot?
        state.onCheckpoint = { received = $0 }

        state.duplicateSelected()

        XCTAssertEqual(received?.action, "Duplicate")
    }

    /// Duplicate and paste share `insertPasted`; a paste must still record
    /// "Paste", not fall through to duplicate's default.
    func testPasteStillRecordsAnUndoCheckpointLabeledPaste() {
        let state = makeState()
        var received: EditorSnapshot?
        state.onCheckpoint = { received = $0 }

        state.insertPasted([rect(10, 10)])

        XCTAssertEqual(received?.action, "Paste")
    }
}
