import XCTest
import AppKit
@testable import Sealshot

/// Remove Background writes an alternate base (`cutoutImage` + `showingCutout`)
/// that `EditorState.displayBase` returns ahead of the source. The canvas only
/// repaints when a property it observes changes, so if the cutout state isn't
/// tracked the canvas keeps showing the old image — the strip thumbnail updates
/// (it reads the state directly), and switching captures and back "fixes" it
/// because that rebuilds the view.
///
/// Nothing else in the write path covers it: `setShowingCutout` touches
/// `showingEnhanced` only when it was already true, and `markDirty` sets
/// `isDirty`, which the canvas doesn't track. The repaint therefore used to
/// depend on an unrelated observed property changing by luck, which is exactly
/// the kind of bug that reproduces on one machine and not another.
@MainActor
final class EditorCanvasCutoutRefreshTests: XCTestCase {

    private func makeImage(_ w: Int = 40, _ h: Int = 30) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// The observation callback hops through a `Task { @MainActor }`, so give
    /// it a turn to run before asserting. Invalidation is counted rather than
    /// read from `needsDisplay`, which an NSView with no window never reports.
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    /// CONTROL: `selectedTool` has always been in the canvas's observation
    /// list, so if this doesn't invalidate either, the harness is measuring the
    /// wrong thing rather than the cutout tracking being absent.
    func test_control_changingAnAlreadyObservedPropertyMarksTheCanvas() async {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let canvas = EditorCanvasView(state: state)
        await settle()
        let before = canvas.debugStateInvalidationCount

        state.selectedTool = .crop
        await settle()

        XCTAssertGreaterThan(canvas.debugStateInvalidationCount, before)
    }

    func test_applyingACutoutMarksTheCanvasForRedraw() async {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let canvas = EditorCanvasView(state: state)
        await settle()
        let before = canvas.debugStateInvalidationCount

        // Exactly what EditorWindowController does when removal succeeds.
        state.cutoutImage = makeImage()
        state.setShowingCutout(true)
        await settle()

        XCTAssertGreaterThan(canvas.debugStateInvalidationCount, before,
                             "applying a cutout must invalidate the canvas")
        XCTAssertTrue(state.displayBase === state.cutoutImage,
                      "the cutout must be the displayed base once shown")
    }

    /// Toggling the cutout off must repaint too — the canvas has to go back to
    /// the source image.
    func test_togglingTheCutoutOffMarksTheCanvasForRedraw() async {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.cutoutImage = makeImage()
        state.setShowingCutout(true)
        let canvas = EditorCanvasView(state: state)
        await settle()
        let before = canvas.debugStateInvalidationCount

        state.setShowingCutout(false)
        await settle()

        XCTAssertGreaterThan(canvas.debugStateInvalidationCount, before,
                             "hiding the cutout must invalidate the canvas")
        XCTAssertTrue(state.displayBase === state.sourceImage,
                      "hiding the cutout must fall back to the source image")
    }

}
