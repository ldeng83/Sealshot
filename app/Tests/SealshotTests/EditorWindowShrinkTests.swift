import XCTest
import AppKit
@testable import Sealshot

/// End-to-end floor check: a real editor window, resized small.
///
/// The unit tests around `EditorToolbarFit` prove the fold arithmetic and that
/// a folded bar fits 560pt. They cannot prove the WINDOW follows, because the
/// binding constraint moves as things change: for a long time it was the tool
/// bar's ~1055pt intrinsic width, which silently overrode the window's own
/// declared minimum. These tests drive the whole constraint chain — bar,
/// canvas floor, sidebar minimum — and assert on what the user actually gets
/// when they drag the window edge.
@MainActor
final class EditorWindowShrinkTests: XCTestCase {

    private func makeImage(_ w: Int = 120, _ h: Int = 90) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makeController() -> EditorWindowController {
        let config = CaptureConfig()
        return EditorWindowController(
            state: EditorState(sourceImage: makeImage(), sourceURL: nil),
            saver: EditorSaveCoordinator(config: config),
            config: config,
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
            title: "shrink",
            onRecentClick: { _ in }
        )
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    /// Resize the way a USER does, not the way code does.
    ///
    /// Two things matter. AppKit asks the delegate `windowWillResize` before
    /// applying a drag — that is where the chrome folds, and a bare
    /// `setContentSize` skips it entirely. And a real drag arrives as a STREAM
    /// of sizes, not one jump: each event folds a little more and lets the
    /// next go further, which is how the window walks down to its minimum.
    private func drag(_ window: NSWindow, toContentWidth width: CGFloat,
                      height: CGFloat = 420) async {
        let from = window.contentLayoutRect.width
        // A handful of steps, as a hand-drag would produce.
        let steps = stride(from: 0.0, through: 1.0, by: 0.25)
            .map { from + (width - from) * $0 }
        for step in steps {
            let content = NSRect(x: 0, y: 0, width: step, height: height)
            let frame = window.frameRect(forContentRect: content)
            _ = window.delegate?.windowWillResize?(window, to: frame.size)
            window.setContentSize(NSSize(width: step, height: height))
            window.layoutIfNeeded()
        }
        await settle()
    }

    /// A drag to the minimum must actually get there. Before the fold existed
    /// the window jammed at the tool bar's 1055pt intrinsic width — the bar's
    /// pills are fixed-size and none of them compress, so the bar, not the
    /// window's declared minimum, decided how small the editor could be.
    func testWindow_shrinksToItsDeclaredMinimum() async {
        let controller = makeController()
        guard let window = controller.window else { return XCTFail("no window") }
        await drag(window, toContentWidth: 1400, height: 800)

        await drag(window, toContentWidth: 560)

        XCTAssertLessThanOrEqual(window.contentLayoutRect.width, 560 + 1,
                                 "the editor still refuses to shrink — something "
                                 + "in the content is wider than the window minimum")
    }

    /// Shrinking folds the bar; growing back restores it. The fold is a
    /// response to width, not a one-way door.
    func testToolbar_foldsOnTheWayDownAndRestoresOnTheWayUp() async {
        let controller = makeController()
        guard let window = controller.window else { return XCTFail("no window") }
        await drag(window, toContentWidth: 1400, height: 800)
        XCTAssertTrue(controller.debugFoldedToolbarClusters.isEmpty,
                      "a wide window shows the whole bar")

        await drag(window, toContentWidth: 560)
        XCTAssertFalse(controller.debugFoldedToolbarClusters.isEmpty,
                       "a narrow window must fold clusters away")

        await drag(window, toContentWidth: 1400, height: 800)
        XCTAssertTrue(controller.debugFoldedToolbarClusters.isEmpty,
                      "widening again must bring the pills back")
    }

    /// The meta row folds on the same principle: its zoom presets collapse to
    /// a menu button, then the slider goes. Nothing is lost — ± and the
    /// editable % readout still drive zoom, and the presets live in the menu.
    func testMetaRow_foldsItsZoomControlsAsTheWindowNarrows() async {
        let controller = makeController()
        guard let window = controller.window else { return XCTFail("no window") }
        guard let row = controller.debugMetaRow else { return XCTFail("no meta row") }
        await drag(window, toContentWidth: 1400, height: 800)
        XCTAssertFalse(row.zoomPresetsCollapsedForTesting)
        XCTAssertFalse(row.zoomSliderCollapsedForTesting)

        await drag(window, toContentWidth: 680)
        XCTAssertTrue(row.zoomPresetsCollapsedForTesting,
                      "the five presets collapse behind one menu button first")
        XCTAssertFalse(row.zoomSliderCollapsedForTesting,
                       "the slider survives until it has to go")

        await drag(window, toContentWidth: 560)
        XCTAssertTrue(row.zoomSliderCollapsedForTesting,
                      "at the minimum the slider folds too")

        await drag(window, toContentWidth: 1400, height: 800)
        XCTAssertFalse(row.zoomPresetsCollapsedForTesting,
                       "widening restores the presets")
        XCTAssertFalse(row.zoomSliderCollapsedForTesting)
    }
}
