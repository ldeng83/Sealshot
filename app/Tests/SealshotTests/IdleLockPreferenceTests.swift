import XCTest
@testable import Sealshot

final class IdleLockPreferenceTests: XCTestCase {
    func testDefaultIsZeroMeaningOff() {
        let d = UserDefaults(suiteName: "idle-\(UUID().uuidString)")!
        XCTAssertEqual(IdleLockPreference(defaults: d).minutes, 0)
    }
    func testPersists() {
        let d = UserDefaults(suiteName: "idle-\(UUID().uuidString)")!
        let p = IdleLockPreference(defaults: d)
        p.minutes = 5
        XCTAssertEqual(IdleLockPreference(defaults: d).minutes, 5)
    }
}
