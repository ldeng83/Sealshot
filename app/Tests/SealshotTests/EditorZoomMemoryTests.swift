import XCTest
import AppKit
@testable import Sealshot

/// Zoom is remembered PER image: switching images keeps each image's own zoom
/// and never bleeds one image's zoom onto another.
@MainActor
final class EditorZoomMemoryTests: XCTestCase {

    private let key = "editorImageZoom"
    private let urlA = URL(fileURLWithPath: "/caps/imgA.seal")
    private let urlB = URL(fileURLWithPath: "/caps/imgB.seal")

    override func setUp() { super.setUp(); UserDefaults.standard.removeObject(forKey: key) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: key); super.tearDown() }

    private func makeImage(_ w: Int = 120, _ h: Int = 90) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func settle() async {
        for _ in 0..<6 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func test_switchingToAnotherImageDoesNotInheritZoom() async {
        // Image A is remembered at 50%.
        ImageZoomMemory.store(0.5, for: urlA)

        let config = CaptureConfig()
        let saver = EditorSaveCoordinator(config: config)
        let state1 = EditorState(sourceImage: makeImage(), sourceURL: urlA)
        let controller = EditorWindowController(
            state: state1, saver: saver, config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "A", onRecentClick: { _ in })
        await settle()

        // Switching to a DIFFERENT image (B, never zoomed) must fit it, not
        // adopt A's 50% — this is the cross-image bleed the fix prevents.
        let state2 = EditorState(sourceImage: makeImage(200, 150), sourceURL: urlB)
        controller.swap(toState: state2, title: "B")
        await settle()

        XCTAssertGreaterThan(abs(state2.zoom - 0.5), 0.01,
                             "image B must not inherit image A's 50% zoom")
    }

    func test_switchingBackRestoresThatImagesZoom() async {
        ImageZoomMemory.store(0.5, for: urlA)

        let config = CaptureConfig()
        let saver = EditorSaveCoordinator(config: config)
        let state1 = EditorState(sourceImage: makeImage(200, 150), sourceURL: urlB)
        let controller = EditorWindowController(
            state: state1, saver: saver, config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "B", onRecentClick: { _ in })
        await settle()

        // Opening A honors A's remembered 50%.
        let stateA = EditorState(sourceImage: makeImage(), sourceURL: urlA)
        controller.swap(toState: stateA, title: "A")
        await settle()

        XCTAssertEqual(stateA.zoom, 0.5, accuracy: 0.001,
                       "returning to image A should restore its own 50% zoom")
    }

    func test_fitWidthZoomIsRememberedPerURL() async {
        let state = EditorState(sourceImage: makeImage(400, 100), sourceURL: urlA)
        let canvas = EditorCanvasView(state: state)
        let scroll = EditorCanvasScrollView(state: state, canvas: canvas)
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        scroll.layoutSubtreeIfNeeded()

        scroll.fitToWidth()   // bypasses setZoomPreservingFocalPoint
        await settle()

        XCTAssertNotNil(ImageZoomMemory.load(for: urlA), "fit-width zoom should be remembered")
        XCTAssertEqual(ImageZoomMemory.load(for: urlA)!, state.zoom, accuracy: 0.001)
    }

    func test_zoomRememberedWhenImageHasFocusCrop() async {
        let state = EditorState(sourceImage: makeImage(400, 300), sourceURL: urlA)
        state.focusRect = CGRect(x: 10, y: 10, width: 100, height: 80)
        let canvas = EditorCanvasView(state: state)
        let scroll = EditorCanvasScrollView(state: state, canvas: canvas)
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        scroll.layoutSubtreeIfNeeded()

        state.zoom = 0.6
        await settle()

        XCTAssertEqual(ImageZoomMemory.load(for: urlA) ?? -1, 0.6, accuracy: 0.001,
                       "zoom must be remembered even when the image has a focus crop")
    }

    func test_unsavedCaptureIsNotRemembered() async {
        let state = EditorState(sourceImage: makeImage(400, 100), sourceURL: nil)
        let canvas = EditorCanvasView(state: state)
        let scroll = EditorCanvasScrollView(state: state, canvas: canvas)
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        scroll.layoutSubtreeIfNeeded()

        state.zoom = 0.7
        await settle()

        XCTAssertNil(ImageZoomMemory.load(for: nil),
                     "an unsaved capture has no key and isn't remembered")
    }

    func test_applyInitialZoomSizesCanvasFrameSynchronously() {
        ImageZoomMemory.store(0.5, for: urlA)
        let state = EditorState(sourceImage: makeImage(200, 100), sourceURL: urlA)
        let canvas = EditorCanvasView(state: state)
        let scroll = EditorCanvasScrollView(state: state, canvas: canvas)
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        scroll.layoutSubtreeIfNeeded()

        scroll.applyInitialZoom()   // no await — frame/magnification must be set

        // Zoom is magnification now: the canvas frame stays NATIVE and the
        // remembered zoom is applied as the scroll view's magnification.
        let pad = EditorCanvasView.imagePadding
        XCTAssertEqual(canvas.frame.width, 200 + pad * 2, accuracy: 0.5)
        XCTAssertEqual(canvas.frame.height, 100 + pad * 2, accuracy: 0.5)
        XCTAssertEqual(scroll.magnification, 0.5, accuracy: 0.001)
    }
}
