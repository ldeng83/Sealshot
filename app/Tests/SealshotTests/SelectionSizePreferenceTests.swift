import XCTest
@testable import Sealshot

final class SelectionSizePreferenceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "SelectionSizePreferenceTests")!
        d.removePersistentDomain(forName: "SelectionSizePreferenceTests")
        return d
    }

    func testNilWhenUnset() {
        XCTAssertNil(SelectionSizePreference.current(freshDefaults()))
    }

    func testRoundTrip() {
        let d = freshDefaults()
        SelectionSizePreference.set(width: 1920, height: 1080, into: d)
        let got = SelectionSizePreference.current(d)
        XCTAssertEqual(got?.width, 1920)
        XCTAssertEqual(got?.height, 1080)
    }

    func testIgnoresNonPositive() {
        let d = freshDefaults()
        SelectionSizePreference.set(width: 0, height: 100, into: d)
        XCTAssertNil(SelectionSizePreference.current(d), "non-positive size must not persist")
    }
}
