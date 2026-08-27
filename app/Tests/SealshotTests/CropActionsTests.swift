import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class CropActionsTests: XCTestCase {
    private func makeState() -> EditorState {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 60, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        return EditorState(sourceImage: ctx.makeImage()!, sourceURL: nil)
    }

    func test_cut_addsCutAnnotation_andClearsPending() {
        let s = makeState()
        s.pendingCrop = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertTrue(s.cutCropRegion())
        XCTAssertNil(s.pendingCrop)
        guard case let .cut(rect) = s.annotations.last?.geometry else {
            return XCTFail("expected a .cut annotation")
        }
        XCTAssertEqual(rect, CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    func test_cut_isUndoable() {
        let s = makeState()
        let h = TimelineTestHarness(s)
        let before = s.annotations.count
        s.pendingCrop = CGRect(x: 5, y: 5, width: 10, height: 10)
        s.cutCropRegion()
        h.undo()
        XCTAssertEqual(s.annotations.count, before)
    }

    func test_copy_keepsPending_andDoesNotMutateAnnotations() {
        let s = makeState()
        let before = s.annotations.count
        s.pendingCrop = CGRect(x: 5, y: 5, width: 10, height: 10)
        XCTAssertTrue(s.copyCropRegion())
        XCTAssertEqual(s.pendingCrop, CGRect(x: 5, y: 5, width: 10, height: 10))
        XCTAssertEqual(s.annotations.count, before)
    }

    func test_actions_returnFalseWithoutSelection() {
        let s = makeState()
        s.pendingCrop = nil
        XCTAssertFalse(s.copyCropRegion())
        XCTAssertFalse(s.cutCropRegion())
    }
}

extension CropActionsTests {
    func test_softCrop_insertsImageObject_andClearsPending() {
        let s = makeState()
        let before = s.annotations.count
        s.pendingCrop = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertTrue(s.softCropRegion())
        XCTAssertNil(s.pendingCrop)
        // Soft crop adds a .cut hole AND a .image overlay = +2 annotations.
        XCTAssertEqual(s.annotations.count, before + 2)
        let cutCount = s.annotations.filter {
            if case .cut = $0.geometry { return true }; return false
        }.count
        XCTAssertEqual(cutCount, 1, "expected exactly one .cut annotation")
        XCTAssertTrue(s.annotations.last?.geometry.isImage == true,
                      "last annotation must be the lifted image overlay")
    }

    func test_softCrop_isUndoableInOneStep() {
        let s = makeState()
        let h = TimelineTestHarness(s)
        let before = s.annotations.count
        s.pendingCrop = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertTrue(s.softCropRegion())
        XCTAssertEqual(s.annotations.count, before + 2)
        h.undo()
        XCTAssertEqual(s.annotations.count, before,
                       "one undo must revert both the hole and the lifted object")
    }

    func test_softCrop_returnsFalseWithoutSelection() {
        let s = makeState()
        s.pendingCrop = nil
        XCTAssertFalse(s.softCropRegion())
    }
}
