import AppKit
import XCTest
@testable import Sealshot

/// The menu item is the only place a repeat capture announces itself — the
/// command takes pixels with no overlay and no confirmation.
final class RepeatCaptureMenuTitleTests: XCTestCase {
    func testTitle_showsTheAreaSize() {
        XCTAssertEqual(RepeatCaptureMenuTitle.forSize(CGSize(width: 640, height: 480)),
                       "Repeat Last Capture (640 × 480)")
    }

    /// A drag ends on fractional points; the user drew a box, not a decimal.
    func testTitle_roundsFractionalDrags() {
        XCTAssertEqual(RepeatCaptureMenuTitle.forSize(CGSize(width: 640.3, height: 479.6)),
                       "Repeat Last Capture (640 × 480)")
    }

    /// Nothing remembered (or nothing usable): the plain title, because the
    /// command means "select a new area" in that state.
    func testTitle_withoutAnArea_saysNothingAboutSize() {
        XCTAssertEqual(RepeatCaptureMenuTitle.forRegion(nil), RepeatCaptureMenuTitle.base)
        XCTAssertFalse(RepeatCaptureMenuTitle.base.contains("×"))
    }

    @MainActor
    func testTitle_fromARegion_usesItsRect() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let region = SelectedRegion(
            globalRect: CGRect(x: 0, y: 0, width: 300, height: 200), screen: screen)
        XCTAssertEqual(RepeatCaptureMenuTitle.forRegion(region),
                       "Repeat Last Capture (300 × 200)")
    }
}

/// The flash is the receipt for a capture that had no visible UI.
@MainActor
final class RepeatCaptureFlashTests: XCTestCase {
    override func tearDown() {
        RepeatCaptureFlash.dismissForTesting()
        super.tearDown()
    }

    func testFlash_appearsOverTheCapturedArea() throws {
        let rect = CGRect(x: 200, y: 200, width: 300, height: 180)
        RepeatCaptureFlash.show(rect: rect, duration: 5)   // long enough to observe
        let frame = try XCTUnwrap(RepeatCaptureFlash.visibleFrameForTesting)
        XCTAssertTrue(frame.contains(rect),
                      "the outline surrounds the captured area rather than covering it")
        // Only the stroke's width, so it never suggests a bigger capture.
        XCTAssertEqual(frame.width, rect.width + RepeatCaptureFlash.lineWidth * 2, accuracy: 0.5)
    }

    /// Two repeats in quick succession must leave ONE flash, not a pile of
    /// panels fading independently over the screen.
    func testFlash_replacesThePreviousOne() throws {
        RepeatCaptureFlash.show(rect: CGRect(x: 0, y: 0, width: 100, height: 100), duration: 5)
        let second = CGRect(x: 400, y: 300, width: 220, height: 140)
        RepeatCaptureFlash.show(rect: second, duration: 5)
        let frame = try XCTUnwrap(RepeatCaptureFlash.visibleFrameForTesting)
        XCTAssertTrue(frame.contains(second), "the newest area is the one shown")
    }

    func testFlash_isClickThroughAndDoesNotTakeFocus() throws {
        RepeatCaptureFlash.show(rect: CGRect(x: 10, y: 10, width: 100, height: 100), duration: 5)
        XCTAssertNotNil(RepeatCaptureFlash.visibleFrameForTesting)
        // The panel must never intercept a click meant for the app being
        // documented, nor steal key focus from it.
        let panels = NSApp.windows.filter { $0.level == .screenSaver && $0.isVisible }
        let flash = try XCTUnwrap(panels.first)
        XCTAssertTrue(flash.ignoresMouseEvents)
        XCTAssertFalse(flash.canBecomeKey)
    }
}
