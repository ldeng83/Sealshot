import XCTest
import AppKit
@testable import Sealshot

/// Reproduction for the "hide strip dead after switching images" bug: the
/// meta row is rebuilt on every state swap, and the rebuilt row must keep
/// the strip toggle wired to the controller and reflect the current
/// hidden state — otherwise the chevron silently does nothing.
@MainActor
final class EditorStripToggleSwapTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "stripHidden")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "stripHidden")
        super.tearDown()
    }

    private func makeImage(_ w: Int = 120, _ h: Int = 90) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    private func makeController(state: EditorState) -> EditorWindowController {
        let config = CaptureConfig()
        let saver = EditorSaveCoordinator(config: config)
        return EditorWindowController(
            state: state,
            saver: saver,
            config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "first",
            onRecentClick: { _ in }
        )
    }

    func test_stripToggleStillHidesStripAfterSwap() async {
        let controller = makeController(state: EditorState(sourceImage: makeImage(), sourceURL: nil))

        let state2 = EditorState(sourceImage: makeImage(), sourceURL: nil)
        controller.swap(toState: state2, title: "second")
        await settle()

        controller.debugClickStripToggle()

        XCTAssertTrue(
            controller.debugStripHidden,
            "chevron on the rebuilt meta row should still collapse the strip"
        )
    }

    func test_rebuiltMetaRowReflectsHiddenState() async {
        let controller = makeController(state: EditorState(sourceImage: makeImage(), sourceURL: nil))

        controller.debugClickStripToggle()
        XCTAssertTrue(controller.debugStripHidden, "precondition: toggle hides before any swap")

        let state2 = EditorState(sourceImage: makeImage(), sourceURL: nil)
        controller.swap(toState: state2, title: "second")
        await settle()

        XCTAssertEqual(
            controller.debugStripToggleTooltip, "Show",
            "rebuilt meta row should show the hidden-state tooltip, not reset to visible"
        )
    }

    func test_toggleTooltipReadsHideWhenStripVisible() {
        let controller = makeController(state: EditorState(sourceImage: makeImage(), sourceURL: nil))
        XCTAssertEqual(controller.debugStripToggleTooltip, "Hide")
    }
}
