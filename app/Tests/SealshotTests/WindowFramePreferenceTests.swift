import XCTest
@testable import Sealshot

/// `WindowFramePreference` persists the editor window's global frame (position +
/// size, across monitors) and validates whether a saved frame is still
/// reachable on the currently-connected displays.
final class WindowFramePreferenceTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WindowFramePreferenceTests-\(UUID().uuidString)")!
    }
    private let laptop = CGRect(x: 0, y: 0, width: 1440, height: 877)

    func test_missing_isNil() {
        XCTAssertNil(WindowFramePreference.load(freshDefaults()))
    }

    func test_roundTrip() {
        let d = freshDefaults()
        let frame = CGRect(x: 120, y: 80, width: 900, height: 600)
        WindowFramePreference.store(frame, d)
        XCTAssertEqual(WindowFramePreference.load(d), frame)
    }

    func test_degenerateFrame_notLoaded() {
        let d = freshDefaults()
        WindowFramePreference.store(CGRect(x: 10, y: 10, width: 0, height: 0), d)
        XCTAssertNil(WindowFramePreference.load(d))
    }

    func test_reachable_fullyOnScreen() {
        XCTAssertTrue(WindowFramePreference.isReachable(
            CGRect(x: 100, y: 80, width: 900, height: 600), on: [laptop]))
    }

    func test_reachable_validNegativeOriginSecondDisplay() {
        // An ultra-wide to the left lives at negative X; a window on it is fine.
        let ultrawide = CGRect(x: -3440, y: 0, width: 3440, height: 1440)
        XCTAssertTrue(WindowFramePreference.isReachable(
            CGRect(x: -3000, y: 200, width: 1600, height: 1000),
            on: [laptop, ultrawide]))
    }

    func test_unreachable_offEveryScreen() {
        // Saved on a now-disconnected monitor far above-left of the laptop.
        XCTAssertFalse(WindowFramePreference.isReachable(
            CGRect(x: -250, y: -1361, width: 2000, height: 1255), on: [laptop]))
    }

    func test_unreachable_sliverOnly() {
        // Only a few points peek onto the display — not enough to grab.
        XCTAssertFalse(WindowFramePreference.isReachable(
            CGRect(x: 1430, y: 850, width: 900, height: 600), on: [laptop]))
    }
}
