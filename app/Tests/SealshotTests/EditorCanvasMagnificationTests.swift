import XCTest
import AppKit
@testable import Sealshot

/// Zoom is applied as `NSScrollView.magnification` (a GPU transform), so the
/// document view stays at NATIVE size and never balloons the layer backing
/// store to `imageSize × zoom`. These assert the geometry invariant.
@MainActor
final class EditorCanvasMagnificationTests: XCTestCase {

    private func makeImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func makeScroll(_ w: Int, _ h: Int) -> (EditorState, EditorCanvasView, EditorCanvasScrollView) {
        let state = EditorState(sourceImage: makeImage(w, h), sourceURL: nil)
        let canvas = EditorCanvasView(state: state)
        let scroll = EditorCanvasScrollView(state: state, canvas: canvas)
        scroll.frame = NSRect(x: 0, y: 0, width: 1000, height: 500)
        scroll.layoutSubtreeIfNeeded()
        return (state, canvas, scroll)
    }

    /// Discrete zoom GLIDES (`withZoomGlide`), so `magnification` is landed by
    /// the animation-group completion handler, not by `setZoom` itself — the
    /// source warns callers to set `state.zoom` and "never read it back".
    /// Reading `magnification` therefore has to wait for the glide to settle.
    private func awaitZoomGlide() {
        let settled = expectation(description: "zoom glide settles")
        let slack = EditorCanvasScrollView.zoomGlideDuration * 2 + 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + slack) { settled.fulfill() }
        wait(for: [settled], timeout: slack + 5)
    }

    func test_zoomSetsMagnificationAndKeepsNativeCanvasFrame() {
        let (state, canvas, scroll) = makeScroll(200, 100)

        scroll.setZoom(0.5)

        let pad = EditorCanvasView.imagePadding
        // Canvas frame stays NATIVE — not multiplied by zoom.
        XCTAssertEqual(canvas.frame.width, 200 + pad * 2, accuracy: 0.5)
        XCTAssertEqual(canvas.frame.height, 100 + pad * 2, accuracy: 0.5)
        // The model zoom is the synchronous half of the contract.
        XCTAssertEqual(state.zoom, 0.5, accuracy: 0.001)
        // Zoom is applied as scroll-view magnification, once the glide lands.
        awaitZoomGlide()
        XCTAssertEqual(scroll.magnification, 0.5, accuracy: 0.001)
    }

    func test_zoomInDoesNotGrowCanvasFrame() {
        let (state, canvas, scroll) = makeScroll(300, 200)
        let pad = EditorCanvasView.imagePadding

        scroll.setZoom(4.0)

        XCTAssertEqual(canvas.frame.width, 300 + pad * 2, accuracy: 0.5,
                       "zooming in must NOT resize the document view")
        XCTAssertEqual(canvas.frame.height, 200 + pad * 2, accuracy: 0.5)
        XCTAssertEqual(state.zoom, 4.0, accuracy: 0.001)
        awaitZoomGlide()
        XCTAssertEqual(scroll.magnification, 4.0, accuracy: 0.001)
    }
}
