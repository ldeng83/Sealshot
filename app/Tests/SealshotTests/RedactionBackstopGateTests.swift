import XCTest
@testable import Sealshot

final class RedactionBackstopGateTests: XCTestCase {
    func testGate_trueOnlyWhenAllThree() {
        XCTAssertTrue(RedactionBackstopGate.shouldRun(thorough: true, aiEnabled: true, fmAvailable: true))
        XCTAssertFalse(RedactionBackstopGate.shouldRun(thorough: false, aiEnabled: true, fmAvailable: true))
        XCTAssertFalse(RedactionBackstopGate.shouldRun(thorough: true, aiEnabled: false, fmAvailable: true))
        XCTAssertFalse(RedactionBackstopGate.shouldRun(thorough: true, aiEnabled: true, fmAvailable: false))
    }
    func testPreference_defaultsFalse_roundTrips() {
        let d = UserDefaults(suiteName: "test.thorough.\(UUID())")!
        XCTAssertFalse(ThoroughScanPreference(defaults: d).enabled)
        ThoroughScanPreference(defaults: d).enabled = true
        XCTAssertTrue(ThoroughScanPreference(defaults: d).enabled)
    }
}
