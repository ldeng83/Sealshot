import XCTest
@testable import Sealshot

/// Auto vs manual mode preference for scrolling capture.
final class AutoScrollPreferenceTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AutoScrollPreferenceTests")
        defaults.removePersistentDomain(forName: "AutoScrollPreferenceTests")
    }

    func testDefaultsToAutoScroll() {
        XCTAssertTrue(AutoScrollPreference.isEnabled(defaults))
    }

    func testDisablePersists() {
        AutoScrollPreference.set(false, into: defaults)
        XCTAssertFalse(AutoScrollPreference.isEnabled(defaults))
    }

    func testReEnablePersists() {
        AutoScrollPreference.set(false, into: defaults)
        AutoScrollPreference.set(true, into: defaults)
        XCTAssertTrue(AutoScrollPreference.isEnabled(defaults))
    }
}
