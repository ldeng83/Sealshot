import XCTest
import AppKit
@testable import Sealshot

/// `EditorCanvasView` implements `draggingEntered`/`performDragOperation`, but
/// AppKit only delivers dragging messages to a view that has REGISTERED for the
/// dragged types. It shipped without that call, so both methods were dead code
/// and dropping an image onto a canvas that already held one silently did
/// nothing. Dropping onto the EMPTY canvas worked, masking it, because
/// `EmptyCanvasView` registers in its own init.
@MainActor
final class EditorCanvasDropTests: XCTestCase {

    private func makeImage(_ w: Int = 120, _ h: Int = 90) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    func test_canvasIsRegisteredForFileURLDrops() {
        let state = EditorState(sourceImage: makeImage(),
                                sourceURL: URL(fileURLWithPath: "/tmp/canvas-drop-test.png"))
        let canvas = EditorCanvasView(state: state)
        XCTAssertTrue(canvas.registeredDraggedTypes.contains(.fileURL),
                      "canvas must register for .fileURL or its drop handlers never fire")
    }

    /// The empty-state canvas was already correct — assert it too, so the two
    /// canvases cannot drift apart again.
    func test_emptyCanvasIsAlsoRegistered() {
        let empty = EmptyCanvasView()
        XCTAssertTrue(empty.registeredDraggedTypes.contains(.fileURL))
    }

    /// The strip vends an eagerly-rendered PNG for a single image tile, and the
    /// canvas only accepts extensions on this whitelist — so a mismatch here
    /// would break strip-to-canvas insertion even with registration in place.
    func test_pngIsAcceptedByTheOverlayWhitelist() {
        XCTAssertTrue(EditorWindowController.overlayRasterExtensions.contains("png"),
                      "the strip's eager drag file is a .png")
    }
}
