import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class EditorStateFocusTests: XCTestCase {
    private func makeState() -> EditorState {
        let ctx = CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return EditorState(sourceImage: ctx.makeImage()!, sourceURL: nil)
    }

    func testFocusRectDefaultsNilAndVisibleSizeIsSource() {
        let s = makeState()
        XCTAssertNil(s.focusRect)
        XCTAssertEqual(s.visibleImageSize, CGSize(width: 100, height: 80))
        XCTAssertEqual(s.effectiveFocusRect, CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    func testUndoRedoRestoresFocusRect() {
        let s = makeState()
        let h = TimelineTestHarness(s)
        s.recordUndoCheckpoint()
        s.focusRect = CGRect(x: 10, y: 10, width: 40, height: 30)
        h.undo()
        XCTAssertNil(s.focusRect)
        h.redo()
        XCTAssertEqual(s.focusRect, CGRect(x: 10, y: 10, width: 40, height: 30))
    }

    func testVisibleSizeReflectsCroppedRect() {
        let s = makeState()
        s.croppedRect = CGRect(x: 5, y: 5, width: 60, height: 40)
        XCTAssertEqual(s.visibleImageSize, CGSize(width: 60, height: 40))
        XCTAssertEqual(s.effectiveFocusRect, CGRect(x: 0, y: 0, width: 60, height: 40))
    }

    func testCommitCropResetsFocusRect() {
        let s = makeState()
        s.focusRect = CGRect(x: 10, y: 10, width: 30, height: 20)
        s.pendingCrop = CGRect(x: 0, y: 0, width: 50, height: 50)
        s.commitCrop()
        XCTAssertNil(s.focusRect)
    }

    /// Backs the "Crop to Focus Area" canvas menu action: cropping to the focus
    /// rect makes it the new image bounds and clears the focus.
    func testCropToFocusRect_becomesCroppedRect_andClearsFocus() {
        let s = makeState()
        let focus = CGRect(x: 10, y: 10, width: 40, height: 30)
        s.focusRect = focus
        s.pendingCrop = focus      // what cropToFocusArea() sets
        s.commitCrop()
        XCTAssertEqual(s.croppedRect, focus)
        XCTAssertNil(s.focusRect)
        XCTAssertEqual(s.visibleImageSize, CGSize(width: 40, height: 30))
    }
}
