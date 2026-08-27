import XCTest
@testable import Sealshot

@MainActor
final class CapturePermissionsTests: XCTestCase {
    func testNonSandboxed_listsAllFour_onlyScreenRecordingRequired() {
        let rows = PermissionRequirement.captureRequirements(sandboxed: false)
        XCTAssertEqual(rows.map(\.id),
                       ["screen-recording", "accessibility", "microphone"])
        // Capture only needs Screen Recording — the rest are shown for context
        // but must not gate the Capture action.
        XCTAssertEqual(rows.filter(\.isRequired).map(\.id), ["screen-recording"])
    }

    func testSandboxed_listsScreenRecordingAndMic_onlyScreenRecordingRequired() {
        let rows = PermissionRequirement.captureRequirements(sandboxed: true)
        XCTAssertEqual(rows.map(\.id), ["screen-recording", "microphone"])
        XCTAssertEqual(rows.filter(\.isRequired).map(\.id), ["screen-recording"])
    }

    // Scrolling capture must show the SAME full four-row list as every other
    // capture (it had drifted to a hand-built two-row list). When auto-scroll
    // is enabled, Accessibility joins Screen Recording as a gating requirement.
    func testScrollCapture_listsAllFour_screenRecordingAndAccessibilityRequired_whenAutoScrollOn() {
        let rows = PermissionRequirement.captureRequirements(
            accessibilityRequired: true, sandboxed: false)
        XCTAssertEqual(rows.map(\.id),
                       ["screen-recording", "accessibility", "microphone"])
        XCTAssertEqual(rows.filter(\.isRequired).map(\.id),
                       ["screen-recording", "accessibility"])
    }

    func testScrollCapture_listsAllFour_accessibilityOptional_whenAutoScrollOff() {
        let rows = PermissionRequirement.captureRequirements(
            accessibilityRequired: false, sandboxed: false)
        XCTAssertEqual(rows.map(\.id),
                       ["screen-recording", "accessibility", "microphone"])
        XCTAssertEqual(rows.filter(\.isRequired).map(\.id), ["screen-recording"])
    }

    // The Accessibility trust query (AXIsProcessTrusted) caches stale-true after
    // a mid-session revocation, so a live auto-scroll failure sets a latch. The
    // checklist row MUST honour that latch and read `.missing`, otherwise the
    // revoked permission would falsely show granted. (enable() clearing the
    // latch isn't unit-tested: it also opens System Settings / fires the AX
    // prompt — verified via the manual revoke test instead.)
    func testAccessibilityRow_showsMissing_whenRevokedLatchSet() async throws {
        let saved = AccessibilityPermission.autoScrollRevoked
        defer { AccessibilityPermission.autoScrollRevoked = saved }

        let row = try XCTUnwrap(
            PermissionRequirement.captureRequirements(accessibilityRequired: true, sandboxed: false)
                .first { $0.id == "accessibility" })

        AccessibilityPermission.autoScrollRevoked = true
        let revoked = await row.state()
        XCTAssertEqual(revoked, .missing,
                       "latch must override the cached-true trust query")
    }
}

final class WelcomeTourPreferenceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.welcome.tour.\(UUID().uuidString)")!
    }

    func testFreshDefaults_tourEnabled() {
        // Never dismissed -> tour shows -> toggle on.
        XCTAssertTrue(WelcomePreference.tourEnabled(freshDefaults()))
    }

    func testSetTourEnabledFalse_marksDismissed() {
        let d = freshDefaults()
        WelcomePreference.setTourEnabled(false, into: d)
        XCTAssertTrue(WelcomePreference.hasShown(d))      // dismissed
        XCTAssertFalse(WelcomePreference.tourEnabled(d))  // toggle off
    }

    func testSetTourEnabledTrue_clearsDismissed() {
        let d = freshDefaults()
        WelcomePreference.setShown(true, into: d)         // start dismissed
        WelcomePreference.setTourEnabled(true, into: d)
        XCTAssertFalse(WelcomePreference.hasShown(d))     // re-enabled
        XCTAssertTrue(WelcomePreference.tourEnabled(d))
    }
}
