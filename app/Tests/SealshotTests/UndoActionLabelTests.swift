import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class UndoActionLabelTests: XCTestCase {

    private func makeImage(_ side: Int = 10) -> CGImage {
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: 4 * side, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func test_undo_returnsTheCheckpointActionLabel() {
        let h = TimelineTestHarness(EditorState(sourceImage: makeImage(), sourceURL: nil))
        h.state.recordUndoCheckpoint(action: "Add Arrow")
        XCTAssertEqual(h.undo(), "Add Arrow")
    }

    func test_redo_returnsTheSameLabel_transferredAcrossStacks() {
        let h = TimelineTestHarness(EditorState(sourceImage: makeImage(), sourceURL: nil))
        h.state.recordUndoCheckpoint(action: "Add Arrow")
        _ = h.undo()
        XCTAssertEqual(h.redo(), "Add Arrow")
    }

    func test_undo_emptyStack_returnsNil() {
        let h = TimelineTestHarness(EditorState(sourceImage: makeImage(), sourceURL: nil))
        XCTAssertNil(h.undo())
    }

    func test_redo_emptyStack_returnsNil() {
        let h = TimelineTestHarness(EditorState(sourceImage: makeImage(), sourceURL: nil))
        XCTAssertNil(h.redo())
    }

    func test_checkpoint_withoutLabel_undoReturnsNil() {
        let h = TimelineTestHarness(EditorState(sourceImage: makeImage(), sourceURL: nil))
        h.state.recordUndoCheckpoint()
        XCTAssertNil(h.undo())
    }
}

/// Toast copy audit (Task 6, Step 1): `presentActionHint`'s canvas-host
/// lookup needs a real window, so it isn't unit testable — but the message
/// format behind it (`actionHintMessage`) and the file-event label mapping
/// (`fileEventLabel`) are pure, and are what the brief's copy-style examples
/// ("Undo: Add Arrow — shot-42", "Undo: Switch Image — shot-42",
/// "Undo: Capture — clip-7") actually pin down.
@MainActor
final class ToastCopyTests: XCTestCase {

    func test_actionHintMessage_crossItemEdit_namesTheItem() {
        XCTAssertEqual(
            EditorWindowController.actionHintMessage(verb: "Undo", action: "Add Arrow", itemName: "shot-42"),
            "Undo: Add Arrow — shot-42")
    }

    func test_actionHintMessage_navigation_namesTheTarget() {
        XCTAssertEqual(
            EditorWindowController.actionHintMessage(verb: "Undo", action: "Switch Image", itemName: "shot-42"),
            "Undo: Switch Image — shot-42")
    }

    func test_actionHintMessage_fileEvent_capture_namesTheClip() {
        XCTAssertEqual(
            EditorWindowController.actionHintMessage(verb: "Undo", action: "Capture", itemName: "clip-7"),
            "Undo: Capture — clip-7")
    }

    func test_actionHintMessage_sameItem_omitsName() {
        XCTAssertEqual(
            EditorWindowController.actionHintMessage(verb: "Redo", action: "Move", itemName: nil),
            "Redo: Move")
    }

    func test_actionHintMessage_emptyStack_bareVerbNoAction() {
        XCTAssertEqual(
            EditorWindowController.actionHintMessage(verb: "Nothing to undo", action: nil),
            "Nothing to undo")
        XCTAssertEqual(
            EditorWindowController.actionHintMessage(verb: "Nothing to redo", action: nil),
            "Nothing to redo")
    }

    func test_actionHintMessage_revert_labelOnlyNoItemName() {
        XCTAssertEqual(
            EditorWindowController.actionHintMessage(verb: "Undo", action: "Revert to Original"),
            "Undo: Revert to Original")
    }

    func test_fileEventLabel_recordingsShareCaptureLabelWithScreenshots() {
        XCTAssertEqual(EditorWindowController.fileEventLabel(.deletion), "Delete capture")
        XCTAssertEqual(EditorWindowController.fileEventLabel(.restoration), "Restore capture")
        XCTAssertEqual(EditorWindowController.fileEventLabel(.importation), "Import")
        XCTAssertEqual(EditorWindowController.fileEventLabel(.capture), "Capture")
    }
}
