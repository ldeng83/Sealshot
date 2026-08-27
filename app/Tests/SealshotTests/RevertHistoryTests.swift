import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class RevertHistoryTests: XCTestCase {
    private func state() -> EditorState {
        let img = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        return EditorState(sourceImage: img, sourceURL: nil)
    }

    func test_recordThenUndoRedo() {
        let h = RevertHistory()
        XCTAssertFalse(h.canUndo)
        let prev = state(); let rev = state()
        let t = Date(timeIntervalSince1970: 500)
        h.record(previous: prev, reverted: rev, at: t)
        XCTAssertTrue(h.canUndo)

        let popped = h.popUndo()
        XCTAssertTrue(popped?.previous === prev)
        XCTAssertTrue(popped?.reverted === rev)
        XCTAssertEqual(popped?.at, t)
        h.pushRedo(popped!)
        XCTAssertFalse(h.canUndo)
        XCTAssertTrue(h.canRedo)

        let redo = h.popRedo()
        XCTAssertTrue(redo?.reverted === rev)
        XCTAssertEqual(redo?.at, t)
    }

    func test_recordClearsRedo() {
        let h = RevertHistory()
        h.record(previous: state(), reverted: state(), at: Date(timeIntervalSince1970: 1))
        h.pushRedo(h.popUndo()!)
        XCTAssertTrue(h.canRedo)
        h.record(previous: state(), reverted: state(), at: Date(timeIntervalSince1970: 2))
        XCTAssertFalse(h.canRedo, "a new revert clears the redo branch")
    }

    func test_clear_dropsBothStacks() {
        let h = RevertHistory()
        h.record(previous: state(), reverted: state(), at: Date(timeIntervalSince1970: 1))
        h.pushRedo(h.popUndo()!)
        h.record(previous: state(), reverted: state(), at: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(h.canUndo)
        h.clear()
        XCTAssertFalse(h.canUndo)
        XCTAssertFalse(h.canRedo)
    }
}
