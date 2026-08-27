import XCTest
@testable import Sealshot

/// A NEW canvas starts with `sourceURL == nil` (`EditorController` builds it as
/// `EditorState(sourceImage:sourceURL: nil)`), and `updateStripPreview()`
/// early-returns without a URL — the strip matches tiles by URL, so there is
/// nothing to push a composite onto yet.
///
/// The first autosave assigns one (`target.sourceURL = newURL`), but
/// `armStripPreviewObservation` never tracked `sourceURL`, so that transition
/// scheduled no render. The thumbnail therefore stayed at whatever the save had
/// written until the user happened to make some OTHER tracked change.
@MainActor
final class StripPreviewURLBindingTests: XCTestCase {

    private func makeImage(_ w: Int = 120, _ h: Int = 90) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makeController(state: EditorState) -> EditorWindowController {
        let config = CaptureConfig()
        return EditorWindowController(
            state: state,
            saver: EditorSaveCoordinator(config: config),
            config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "strip-preview-url-binding",
            onRecentClick: { _ in }
        )
    }

    /// Let the debounce (0.25s) and any trailing strip work settle.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 700_000_000)
    }

    /// Assigning a URL to a previously-unsaved canvas must schedule a preview
    /// render, so the tile that appears at first save immediately reflects the
    /// annotations already on the canvas.
    func test_assigningSourceURLSchedulesAStripPreviewRender() async {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        // `currentTab` defaults to `.recent`, which is what updateStripPreview
        // requires — no tab switch needed.
        let controller = makeController(state: state)

        await settle()
        let before = controller.debugStripPreviewRenderCount

        // What the first autosave does (EditorWindowController:2595).
        state.sourceURL = URL(fileURLWithPath: "/tmp/strip-preview-binding-test.seal")
        await settle()

        XCTAssertGreaterThan(
            controller.debugStripPreviewRenderCount, before,
            "assigning sourceURL must re-arm the preview, or a new canvas's tile "
            + "stays stale until some other tracked property happens to change")
    }
}
