import XCTest
import CoreGraphics
@testable import Sealshot

/// Switching captures must cancel an in-flight Enhance Clarity run.
///
/// It used to keep running: the swap hid the "Enhancing…" overlay and the
/// identity guard threw the result away when it finally landed, so the work was
/// wasted — and worse, `isEnhancing` stayed true until it finished, which made
/// Enhance Clarity on the newly-opened capture silently do nothing.
///
/// `onEnhanceCancel` already existed and already routed to the enhance task,
/// but it only fired when a LIVE TEXT enhance session was active. A run the
/// user started themselves left that session nil, so the hook never fired.
@MainActor
final class EnhanceCancelOnSwapTests: XCTestCase {

    private func img(_ w: Int = 4) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: w, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func makeController(_ state: EditorState) -> EditorWindowController {
        let config = CaptureConfig()
        return EditorWindowController(
            state: state,
            saver: EditorSaveCoordinator(config: config),
            config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "enhance-cancel-test",
            onRecentClick: { _ in })
    }

    func test_swappingCaptures_cancelsAnInFlightEnhance() {
        let first = EditorState(sourceImage: img(),
                                sourceURL: URL(fileURLWithPath: "/tmp/enhance-cancel-a.png"))
        let controller = makeController(first)

        var cancels = 0
        controller.onEnhanceCancel = { cancels += 1 }

        controller.swap(toState: EditorState(
            sourceImage: img(),
            sourceURL: URL(fileURLWithPath: "/tmp/enhance-cancel-b.png")), title: "b")

        XCTAssertEqual(cancels, 1,
                       "switching captures must cancel an in-flight enhance")
    }

    /// Redaction and Extract Data cancelled themselves at each navigation SITE
    /// (`presentFile`, `presentRecording`) rather than at the swap. `present(_:)`
    /// — the path a brand-new capture takes — calls `swap` without either, so
    /// taking a screenshot mid-scan left the work running against the capture
    /// the user had just navigated away from. Cancelling in `swap` covers every
    /// path by construction instead of by remembering each call site.
    func test_swappingCaptures_cancelsAnInFlightRedactionScan() {
        let first = EditorState(sourceImage: img(),
                                sourceURL: URL(fileURLWithPath: "/tmp/redact-cancel-a.png"))
        let controller = makeController(first)

        var cancels = 0
        controller.onRedactionScanCancel = { cancels += 1 }

        controller.swap(toState: EditorState(
            sourceImage: img(),
            sourceURL: URL(fileURLWithPath: "/tmp/redact-cancel-b.png")), title: "b")

        XCTAssertEqual(cancels, 1,
                       "switching captures must cancel an in-flight redaction scan")
    }

    /// A cancelled Live Text read still runs its task `defer`, which reports
    /// "recognition finished" asynchronously — after the cancel already tore the
    /// overlay down. That late signal must not reach into the SHARED canvas
    /// overlay and dismiss whatever is using it by then: cancel Live Text,
    /// start a redaction scan, and the scan's overlay vanished.
    func test_lateLiveTextFinishDoesNotDismissAnotherFeaturesOverlay() {
        let controller = makeController(EditorState(
            sourceImage: img(), sourceURL: URL(fileURLWithPath: "/tmp/overlay-owner.png")))

        controller.showLiveTextProgress("Recognizing text…")
        XCTAssertTrue(controller.debugCanvasProgressOverlayVisible)

        controller.showLiveTextProgress(nil)              // user cancels
        XCTAssertFalse(controller.debugCanvasProgressOverlayVisible)

        // Another feature claims the shared overlay.
        controller.showCanvasProgressOverlay(progress: CanvasProgress()) {}
        XCTAssertTrue(controller.debugCanvasProgressOverlayVisible)

        controller.showLiveTextProgress(nil)              // the cancelled task's defer, late
        XCTAssertTrue(controller.debugCanvasProgressOverlayVisible,
                      "a finished Live Text read must not dismiss an overlay it no longer owns")
    }

    /// The toolbar/tab freeze must track what is ON SCREEN, not a running
    /// tally of begin/end calls. It used to be a counter incremented in the two
    /// `show…Overlay` methods and decremented in their `hide` counterparts; one
    /// missed decrement anywhere in the async cancel/finish paths left the tabs
    /// dead for the rest of the session. Interleave both overlays and check the
    /// gate matches reality at every step.
    func test_blockingGateTracksOverlayPresence_notCallBalance() {
        let controller = makeController(EditorState(
            sourceImage: img(), sourceURL: URL(fileURLWithPath: "/tmp/gate.png")))

        XCTAssertFalse(controller.debugBlockingOverlayActive)

        controller.showEnhancingOverlay(progress: EnhanceProgress())
        XCTAssertTrue(controller.debugBlockingOverlayActive)

        controller.showCanvasProgressOverlay(progress: CanvasProgress()) {}
        XCTAssertTrue(controller.debugBlockingOverlayActive)

        // One of two gone is still one on screen.
        controller.hideEnhancingOverlay()
        XCTAssertTrue(controller.debugBlockingOverlayActive)

        // Redundant hides are no-ops, not unbalanced releases.
        controller.hideEnhancingOverlay()
        XCTAssertTrue(controller.debugBlockingOverlayActive)

        controller.hideCanvasProgressOverlay()
        XCTAssertFalse(controller.debugBlockingOverlayActive,
                       "with no overlay on screen, navigation must be live again")
    }

    /// Navigating re-derives the gate, so a stale freeze can never outlive a
    /// tab switch even if some future path forgets to release it.
    func test_tabNavigationReDerivesTheBlockingGate() {
        let controller = makeController(EditorState(
            sourceImage: img(), sourceURL: URL(fileURLWithPath: "/tmp/gate-nav.png")))

        controller.showCanvasProgressOverlay(progress: CanvasProgress()) {}
        controller.selectTab(.editor)
        XCTAssertTrue(controller.debugBlockingOverlayActive)

        controller.hideCanvasProgressOverlay()
        controller.selectTab(.editor)
        XCTAssertFalse(controller.debugBlockingOverlayActive)
    }
}
