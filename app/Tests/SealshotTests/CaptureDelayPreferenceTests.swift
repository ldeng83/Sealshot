import XCTest
@testable import Sealshot

final class CaptureDelayPreferenceTests: XCTestCase {

    func testDurations_areTheOfferedSet() {
        XCTAssertEqual(CaptureDelayPreference.durations, [3, 5, 10, 15])
    }

    func testCurrent_unset_returnsDefault() {
        let d = makeDefaults()
        XCTAssertEqual(CaptureDelayPreference.current(d), CaptureDelayPreference.defaultDuration)
        XCTAssertEqual(CaptureDelayPreference.defaultDuration, 3)
    }

    func testSet_thenCurrent_roundTrips() {
        let d = makeDefaults()
        CaptureDelayPreference.set(10, into: d)
        XCTAssertEqual(CaptureDelayPreference.current(d), 10)
    }

    func testSet_invalidValue_fallsBackToDefault() {
        let d = makeDefaults()
        CaptureDelayPreference.set(7, into: d)   // not in the offered set
        XCTAssertEqual(CaptureDelayPreference.current(d), CaptureDelayPreference.defaultDuration)
    }

    func testCurrent_storedOutOfSet_returnsDefault() {
        let d = makeDefaults()
        d.set(99, forKey: "captureDelaySeconds")
        XCTAssertEqual(CaptureDelayPreference.current(d), CaptureDelayPreference.defaultDuration)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "CaptureDelayPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
