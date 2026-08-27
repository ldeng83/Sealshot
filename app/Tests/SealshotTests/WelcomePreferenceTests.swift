import XCTest
@testable import Sealshot

/// One-time gate for the first-launch welcome window.
final class WelcomePreferenceTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "WelcomePreferenceTests")
        defaults.removePersistentDomain(forName: "WelcomePreferenceTests")
    }

    func testFreshInstall_welcomeNotShownYet() {
        XCTAssertFalse(WelcomePreference.hasShown(defaults))
    }

    func testMarkShown_persists() {
        WelcomePreference.markShown(into: defaults)
        XCTAssertTrue(WelcomePreference.hasShown(defaults))
    }

    func testSetShown_persistsTrueAndFalse() {
        XCTAssertFalse(WelcomePreference.hasShown(defaults))
        WelcomePreference.setShown(true, into: defaults)
        XCTAssertTrue(WelcomePreference.hasShown(defaults))
        WelcomePreference.setShown(false, into: defaults)
        XCTAssertFalse(WelcomePreference.hasShown(defaults))
    }
}
