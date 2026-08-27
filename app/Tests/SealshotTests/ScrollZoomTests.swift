import XCTest
import CoreGraphics
@testable import Sealshot

final class ScrollZoomTests: XCTestCase {

    func test_scrollUp_zoomsIn() {
        XCTAssertGreaterThan(
            EditorCanvasScrollView.zoomByScroll(1.0, scrollDeltaY: 10, precise: false), 1.0)
    }

    func test_scrollDown_zoomsOut() {
        XCTAssertLessThan(
            EditorCanvasScrollView.zoomByScroll(1.0, scrollDeltaY: -10, precise: false), 1.0)
    }

    func test_clampsToMax() {
        XCTAssertEqual(
            EditorCanvasScrollView.zoomByScroll(EditorCanvasScrollView.manualMaxZoom,
                                                scrollDeltaY: 5000, precise: false),
            EditorCanvasScrollView.manualMaxZoom, accuracy: 0.0001)
    }

    func test_clampsToMin() {
        XCTAssertEqual(
            EditorCanvasScrollView.zoomByScroll(EditorCanvasScrollView.minZoom,
                                                scrollDeltaY: -5000, precise: false),
            EditorCanvasScrollView.minZoom, accuracy: 0.0001)
    }

    func test_zeroDelta_noChange() {
        XCTAssertEqual(
            EditorCanvasScrollView.zoomByScroll(2.0, scrollDeltaY: 0, precise: false),
            2.0, accuracy: 0.0001)
    }

    func test_wheelMoreAggressiveThanTrackpad_forSameDelta() {
        // A notched wheel delta should zoom more than the same precise-trackpad
        // delta, so both feel comparable in practice.
        let wheel = EditorCanvasScrollView.zoomByScroll(1.0, scrollDeltaY: 10, precise: false)
        let trackpad = EditorCanvasScrollView.zoomByScroll(1.0, scrollDeltaY: 10, precise: true)
        XCTAssertGreaterThan(wheel, trackpad)
    }
}
