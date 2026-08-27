import XCTest
@testable import Sealshot

final class StripHeightPreferenceTests: XCTestCase {

    func testClamp_belowMin_returnsMin() {
        XCTAssertEqual(StripHeightPreference.clamp(50), StripHeightPreference.minHeight)
    }

    func testClamp_aboveMax_returnsMax() {
        XCTAssertEqual(StripHeightPreference.clamp(9999), StripHeightPreference.maxHeight)
    }

    func testClamp_withinRange_unchanged() {
        XCTAssertEqual(StripHeightPreference.clamp(200), 200)
    }

    func testThumbHeight_subtractsChrome() {
        XCTAssertEqual(StripHeightPreference.thumbHeight(forStripHeight: 146), 88)
        XCTAssertEqual(StripHeightPreference.thumbHeight(forStripHeight: 278), 220)
    }

    func testLoad_unset_returnsDefault() {
        let defaults = makeDefaults()
        XCTAssertEqual(StripHeightPreference.load(defaults), StripHeightPreference.defaultHeight)
    }

    func testLoad_storedOutOfRange_isClamped() {
        let defaults = makeDefaults()
        defaults.set(Double(9999), forKey: "stripHeight")
        XCTAssertEqual(StripHeightPreference.load(defaults), StripHeightPreference.maxHeight)
    }

    func testStore_thenLoad_roundTrips() {
        let defaults = makeDefaults()
        StripHeightPreference.store(210, into: defaults)
        XCTAssertEqual(StripHeightPreference.load(defaults), 210)
    }

    func testStore_clampsBeforePersisting() {
        let defaults = makeDefaults()
        StripHeightPreference.store(40, into: defaults)
        XCTAssertEqual(StripHeightPreference.load(defaults), StripHeightPreference.minHeight)
    }

    /// Isolated, empty defaults so tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suite = "StripHeightPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
