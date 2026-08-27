import XCTest
@testable import Sealshot

/// The quiet-capture rule, tested against the pure predicate rather than a
/// window: a capture started from the floating window must not summon the
/// editor — that summoning is the behaviour the whole feature exists to avoid.
final class FloatingCaptureQuietTests: XCTestCase {

    private let saved = URL(fileURLWithPath: "/tmp/x.seal")

    func testNormalCapture_stillOpensTheEditor() {
        XCTAssertTrue(CaptureCoordinator.shouldOpenEditor(
            output: .file, savedFileURL: saved, startedFromFloatingWindow: false))
    }

    func testClipboardOnlyCapture_stillKeepsTheEditorHidden() {
        XCTAssertFalse(CaptureCoordinator.shouldOpenEditor(
            output: .clipboard, savedFileURL: nil, startedFromFloatingWindow: false))
    }

    func testFloatingWindowCapture_staysQuiet() {
        XCTAssertFalse(CaptureCoordinator.shouldOpenEditor(
            output: .file, savedFileURL: saved, startedFromFloatingWindow: true))
    }

    /// Quiet even with the editor open, which is the COMMON case — the panel is
    /// opened from the editor's toolbar, so the editor is usually still there.
    /// Keying this on editor visibility made the panel do nothing at all in its
    /// most common state: every capture re-summoned the window it exists to
    /// avoid, and the count reset to zero each time.
    func testFloatingWindowCapture_isQuietEvenWithTheEditorOpen() {
        XCTAssertFalse(CaptureCoordinator.shouldOpenEditor(
            output: .both, savedFileURL: saved, startedFromFloatingWindow: true))
    }

    // MARK: A window the user closed stays closed

    /// Closing the editor is a decision. A capture landing afterwards must not
    /// drag the window back over whatever the user is documenting — the shot
    /// still reaches the Library and the recent strip either way.
    func testCaptureAfterTheUserClosedTheEditor_leavesItClosed() {
        XCTAssertFalse(CaptureCoordinator.shouldOpenEditor(
            output: .file, savedFileURL: saved, startedFromFloatingWindow: false,
            userClosedEditor: true))
    }

    /// Saving to both destinations is still a save — same rule.
    func testCaptureToBoth_afterClosing_leavesItClosed() {
        XCTAssertFalse(CaptureCoordinator.shouldOpenEditor(
            output: .both, savedFileURL: saved, startedFromFloatingWindow: false,
            userClosedEditor: true))
    }

    /// The window merely being hidden for the capture is NOT closing it —
    /// `dismissWithAutoSave` hides it every time and expects it back.
    func testCaptureWithTheEditorMerelyHidden_stillOpensIt() {
        XCTAssertTrue(CaptureCoordinator.shouldOpenEditor(
            output: .file, savedFileURL: saved, startedFromFloatingWindow: false,
            userClosedEditor: false))
    }

    /// Clipboard-only wins regardless of origin — there is nothing to show.
    func testClipboardOnly_fromTheFloatingWindow_isStillQuiet() {
        XCTAssertFalse(CaptureCoordinator.shouldOpenEditor(
            output: .clipboard, savedFileURL: nil, startedFromFloatingWindow: true))
    }

    /// Ending a floating capture must be safe to call more than once and from
    /// paths that never started one.
    ///
    /// The panel hides itself the moment a capture is triggered, and only
    /// `endFloatingWindowCapture` brings it back. Every exit therefore has to
    /// call it — including the ones that return before any capture session
    /// exists (a refused licence, a busy screen, a permission checklist) and
    /// the ones that bypass `presentCaptured` entirely (Save As, Live
    /// Capture). Both of those classes stranded the panel. Since the calls are
    /// now sprinkled across every exit, being idempotent is what keeps that
    /// safe.
    @MainActor
    func testEndFloatingWindowCapture_isIdempotent() {
        let coordinator = CaptureCoordinator()
        var restores = 0
        coordinator.floatingWindowCaptureEnded = { restores += 1 }

        coordinator.beginFloatingWindowCapture()
        coordinator.endFloatingWindowCapture()
        coordinator.endFloatingWindowCapture()
        coordinator.endFloatingWindowCapture()
        XCTAssertEqual(restores, 1, "only the first end restores the panel")

        // A path that never began a floating capture must not restore anything.
        coordinator.endFloatingWindowCapture()
        XCTAssertEqual(restores, 1)
    }

    @MainActor
    func testEndFloatingWindowCapture_clearsTheOriginFlag() {
        let coordinator = CaptureCoordinator()
        coordinator.beginFloatingWindowCapture()
        XCTAssertTrue(coordinator.captureOriginIsFloatingWindow)
        coordinator.endFloatingWindowCapture()
        XCTAssertFalse(coordinator.captureOriginIsFloatingWindow,
                       "a stale flag would silence the editor for the NEXT capture")
    }
}
