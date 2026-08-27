import XCTest
import AppKit
@testable import Sealshot

/// Dragging an object mutates `state.annotations` on every mouse event.
/// Observers that do heavy work (full-resolution strip-preview composite,
/// sidebar panel teardown/rebuild) must coalesce those bursts instead of
/// running per tick — per-tick they add user-visible drag latency.
@MainActor
final class EditorDragPerformanceTests: XCTestCase {

    private func makeImage(_ w: Int = 120, _ h: Int = 90) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makeAnnotation(x: CGFloat) -> Annotation {
        Annotation(
            geometry: .rectangle(rect: CGRect(x: x, y: 10, width: 30, height: 20)),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 2,
                         fillColor: nil)
        )
    }

    /// Simulate a 20-tick drag: one annotations mutation per runloop turn,
    /// like real mouseDragged events, so one-shot observers re-arm between
    /// ticks.
    private func simulateDrag(on state: EditorState) async {
        for i in 0..<20 {
            state.annotations = [makeAnnotation(x: CGFloat(10 + i))]
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5ms between ticks
        }
    }

    private func awaitTrailingWork() async {
        try? await Task.sleep(nanoseconds: 500_000_000)     // past any debounce
    }

    /// Wait until the preview counter stops moving, instead of for a fixed
    /// duration.
    ///
    /// The strip renders a preview for its own reasons too — `onContentApplied`
    /// fires when it finishes loading the REAL library behind this test — and
    /// that load takes longer the more captures the machine has. Once it
    /// outran the fixed sleep, it landed inside the measured window and read
    /// as an extra drag render: the test failed with "2 renders" on any
    /// well-used library, and passed on a fresh one. Baselining after
    /// quiescence makes the measurement about the drag alone.
    ///
    /// Only the BASELINE waits this way. The measured windows keep counting
    /// everything, so a genuine double-render still fails the assertion.
    private func awaitPreviewQuiescence(_ controller: EditorWindowController) async {
        var last = -1
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let now = controller.debugStripPreviewRenderCount
            if now == last { return }
            last = now
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTFail("strip preview never settled — something is rendering continuously")
    }

    func test_stripPreviewRenderCoalescesDragBurst() async {
        let config = CaptureConfig()
        let saver = EditorSaveCoordinator(config: config)
        let state = EditorState(
            sourceImage: makeImage(),
            sourceURL: URL(fileURLWithPath: "/tmp/drag-perf-test.png")
        )
        let controller = EditorWindowController(
            state: state,
            saver: saver,
            config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "perf",
            onRecentClick: { _ in }
        )

        await awaitPreviewQuiescence(controller)
        let before = controller.debugStripPreviewRenderCount
        await simulateDrag(on: state)
        await awaitTrailingWork()
        let renders = controller.debugStripPreviewRenderCount - before

        XCTAssertLessThanOrEqual(
            renders, 3,
            "a 20-tick drag should coalesce to a few strip-preview renders, got \(renders)"
        )
        XCTAssertGreaterThanOrEqual(
            renders, 1,
            "the trailing render must still happen so the thumbnail reflects the edit"
        )
    }

    /// A pointer pause mid-drag lets trailing debounces elapse — the heavy
    /// work must still hold off until the interaction ends (mouseUp clears
    /// `interactionInProgress`), then run once.
    func test_stripPreviewDeferredWhileInteractionInProgress() async {
        let config = CaptureConfig()
        let saver = EditorSaveCoordinator(config: config)
        let state = EditorState(
            sourceImage: makeImage(),
            sourceURL: URL(fileURLWithPath: "/tmp/drag-perf-test-2.png")
        )
        let controller = EditorWindowController(
            state: state,
            saver: saver,
            config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "perf",
            onRecentClick: { _ in }
        )

        await awaitPreviewQuiescence(controller)
        let before = controller.debugStripPreviewRenderCount

        state.interactionInProgress = true      // as the canvas does on mouseDown
        state.annotations = [makeAnnotation(x: 10)]
        await awaitTrailingWork()               // a long mid-drag pointer pause
        XCTAssertEqual(
            controller.debugStripPreviewRenderCount - before, 0,
            "no full-res composite may run while the drag is in flight"
        )

        state.interactionInProgress = false     // mouseUp
        await awaitTrailingWork()
        XCTAssertEqual(
            controller.debugStripPreviewRenderCount - before, 1,
            "the deferred render must run once after the drag ends"
        )
    }

    func test_sidebarRebuildDeferredWhileInteractionInProgress() async {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let sidebar = EditorSidebarView(state: state)

        await awaitTrailingWork()
        let before = sidebar.debugRebuildCount

        state.interactionInProgress = true
        state.annotations = [makeAnnotation(x: 10)]
        await awaitTrailingWork()
        XCTAssertEqual(sidebar.debugRebuildCount - before, 0,
                       "no panel rebuild may run while the drag is in flight")

        state.interactionInProgress = false
        await awaitTrailingWork()
        XCTAssertEqual(sidebar.debugRebuildCount - before, 1,
                       "the deferred rebuild must run once after the drag ends")
    }

    func test_sidebarRebuildCoalescesDragBurst() async {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let sidebar = EditorSidebarView(state: state)

        await awaitTrailingWork()
        let before = sidebar.debugRebuildCount
        await simulateDrag(on: state)
        await awaitTrailingWork()
        let rebuilds = sidebar.debugRebuildCount - before

        XCTAssertLessThanOrEqual(
            rebuilds, 3,
            "a 20-tick drag should coalesce to a few sidebar rebuilds, got \(rebuilds)"
        )
        XCTAssertGreaterThanOrEqual(
            rebuilds, 1,
            "the trailing rebuild must still happen so the objects list stays current"
        )
    }
}
