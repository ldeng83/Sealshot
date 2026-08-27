import XCTest
@testable import Sealshot

/// Auto-scan-on-open preference for smart redaction.
final class SmartRedactionPreferenceTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SmartRedactionPreferenceTests")
        defaults.removePersistentDomain(forName: "SmartRedactionPreferenceTests")
    }

    func testDefaultsToOff() {
        XCTAssertFalse(SmartRedactionPreference.autoScanEnabled(defaults))
    }

    func testEnablePersists() {
        SmartRedactionPreference.setAutoScan(true, into: defaults)
        XCTAssertTrue(SmartRedactionPreference.autoScanEnabled(defaults))
    }

    func testDisablePersists() {
        SmartRedactionPreference.setAutoScan(true, into: defaults)
        SmartRedactionPreference.setAutoScan(false, into: defaults)
        XCTAssertFalse(SmartRedactionPreference.autoScanEnabled(defaults))
    }
}
