import XCTest
import AppKit
@testable import Sealshot

/// Reproduction for the "zoom % frozen after switching images" bug: after
/// a loaded→loaded swap (clicking a different thumbnail), the meta row must
/// observe the NEW state, so zoom changes still update the percentage.
@MainActor
final class EditorSwapZoomTests: XCTestCase {

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

    func test_metaRowTracksZoomAfterLoadedToLoadedSwap() async {
        let config = CaptureConfig()
        let saver = EditorSaveCoordinator(config: config)

        let state1 = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let controller = EditorWindowController(
            state: state1,
            saver: saver,
            config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "first",
            onRecentClick: { _ in }
        )

        let state2 = EditorState(sourceImage: makeImage(), sourceURL: nil)
        controller.swap(toState: state2, title: "second")
        await settle()

        state2.zoom = 0.5
        await settle()

        XCTAssertEqual(
            controller.debugMetaPercentText, "50%",
            "meta row should reflect the swapped-in state's zoom"
        )
    }
}
