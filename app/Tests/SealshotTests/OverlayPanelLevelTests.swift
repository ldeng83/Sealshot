import XCTest
import AppKit
@testable import Sealshot

/// The region-selection and window-picker overlays are shown over whatever the
/// user is capturing — including apps in native full-screen mode. A full-screen
/// app runs in its own Space, and an *activating* window gets bound to our own
/// Space and refuses to join the foreground full-screen Space, so the overlay
/// ends up buried behind it. The fix (verified at runtime) is the
/// `.nonactivatingPanel` style: a non-activating palette floats onto whatever
/// Space is active. The high level + all-spaces collection behavior are
/// necessary too — for z-order and Space membership respectively — but the
/// non-activating style is what actually lets the panel reach a full-screen
/// app's Space.
final class OverlayPanelLevelTests: XCTestCase {

    private func anyScreen() throws -> NSScreen {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no screen available in this environment")
        }
        return screen
    }

    func testRegionOverlay_isNonActivating() throws {
        XCTAssertTrue(
            OverlayPanel(screen: try anyScreen()).styleMask.contains(.nonactivatingPanel),
            "region overlay must be non-activating to reach a full-screen app's Space")
    }

    func testWindowPickerOverlay_isNonActivating() throws {
        XCTAssertTrue(
            WindowPickerPanel(screen: try anyScreen()).styleMask.contains(.nonactivatingPanel),
            "window picker must be non-activating to reach a full-screen app's Space")
    }

    func testOverlays_floatAboveFullScreenAppsAndJoinAllSpaces() throws {
        // Level governs z-order once on the Space; the collection behavior lets
        // the panel onto the active (full-screen) Space. Guard both halves.
        for panel in [OverlayPanel(screen: try anyScreen()) as NSPanel,
                      WindowPickerPanel(screen: try anyScreen())] {
            XCTAssertGreaterThanOrEqual(
                panel.level.rawValue, NSWindow.Level.screenSaver.rawValue,
                "overlay must sit at/above .screenSaver for z-order over full-screen apps")
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        }
    }
}
