import XCTest
@testable import Sealshot

/// The recording flow must preflight Screen Recording permission and surface
/// the shared permission checklist — exactly like still capture — BEFORE it
/// runs the recording-setup confirmation prompt. Previously it ran the setup
/// prompt first and then threw a raw error when ScreenCaptureKit was denied.
@MainActor
final class RecordingPermissionGateTests: XCTestCase {
    private func makeCoordinator() -> RecordingCoordinator {
        RecordingCoordinator(
            saveFolder: { URL(fileURLWithPath: NSTemporaryDirectory()) },
            countdown: CaptureCountdownController(),
            sourcePicker: { nil })
    }

    func test_fullScreen_whenScreenRecordingDenied_showsChecklistBeforeSetupPrompt() async {
        let rec = makeCoordinator()
        rec.screenRecordingPreflight = { false }
        let shown = expectation(description: "checklist shown")
        var setupPromptCalled = false
        var editorHidden = false
        rec.showPermissionChecklist = { _ in shown.fulfill() }
        rec.confirmSettings = { setupPromptCalled = true; return true }
        rec.onWillBegin = { editorHidden = true }

        rec.begin()
        await fulfillment(of: [shown], timeout: 2)

        XCTAssertFalse(setupPromptCalled, "permission gate must run before the recording setup prompt")
        XCTAssertFalse(editorHidden, "must not hide the editor just to show the permission checklist")
    }

    func test_selection_whenScreenRecordingDenied_showsChecklistBeforeSetupPrompt() async {
        let rec = makeCoordinator()
        rec.screenRecordingPreflight = { false }
        let shown = expectation(description: "checklist shown")
        var setupPromptCalled = false
        rec.showPermissionChecklist = { _ in shown.fulfill() }
        rec.confirmSettings = { setupPromptCalled = true; return true }

        rec.beginSelection()
        await fulfillment(of: [shown], timeout: 2)

        XCTAssertFalse(setupPromptCalled, "permission gate must run before the recording setup prompt")
    }

    // The bug: CGPreflightScreenCaptureAccess can return a STALE "granted" after
    // the user revokes Screen Recording. Trusting it alone sent recording into a
    // ScreenCaptureKit call that threw a raw error (after the setup prompt). The
    // honest live check must catch this and surface the checklist instead.
    func test_stalePreflightButLiveDenied_showsChecklistNotError() async {
        let rec = makeCoordinator()
        rec.screenRecordingPreflight = { true }    // stale cached grant
        rec.screenRecordingLiveCheck = { false }   // actually revoked
        let shown = expectation(description: "checklist shown")
        var setupPromptCalled = false
        rec.showPermissionChecklist = { _ in shown.fulfill() }
        rec.confirmSettings = { setupPromptCalled = true; return true }

        rec.begin()
        await fulfillment(of: [shown], timeout: 2)

        XCTAssertFalse(setupPromptCalled,
                       "a stale preflight grant must not let recording reach the setup prompt / SCK")
    }

    func test_whenGranted_proceedsToSetupPromptWithoutChecklist() async {
        let rec = makeCoordinator()
        rec.screenRecordingPreflight = { true }
        rec.screenRecordingLiveCheck = { true }
        let reachedSetup = expectation(description: "setup prompt reached")
        var checklistShown = false
        rec.showPermissionChecklist = { _ in checklistShown = true }
        rec.onAborted = {}
        // Cancel at the setup prompt so the flow stops before real ScreenCaptureKit.
        rec.confirmSettings = { reachedSetup.fulfill(); return false }

        rec.begin()
        await fulfillment(of: [reachedSetup], timeout: 2)

        XCTAssertFalse(checklistShown, "granted permission must not show the checklist")
    }

    func test_whenScreenRecordingDenied_retryReentersRecording() async {
        let rec = makeCoordinator()
        rec.screenRecordingPreflight = { false }
        let shown = expectation(description: "checklist shown")
        var capturedRetry: (() -> Void)?
        rec.showPermissionChecklist = { retry in capturedRetry = retry; shown.fulfill() }

        rec.begin()
        await fulfillment(of: [shown], timeout: 2)

        XCTAssertNotNil(capturedRetry, "checklist must receive a retry closure that restarts recording")
    }
}
