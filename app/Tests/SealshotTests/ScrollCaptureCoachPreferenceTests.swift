import XCTest
@testable import Sealshot

/// One-time gate for the scrolling-capture coach card.
final class ScrollCaptureCoachPreferenceTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ScrollCaptureCoachPreferenceTests")
        defaults.removePersistentDomain(forName: "ScrollCaptureCoachPreferenceTests")
    }

    func testFreshInstall_coachNotShownYet() {
        XCTAssertFalse(ScrollCaptureCoachPreference.hasShown(defaults))
    }

    func testMarkShown_persists() {
        ScrollCaptureCoachPreference.markShown(into: defaults)
        XCTAssertTrue(ScrollCaptureCoachPreference.hasShown(defaults))
    }
}
