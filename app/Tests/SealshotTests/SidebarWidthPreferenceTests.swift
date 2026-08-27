import XCTest
@testable import Sealshot

final class SidebarWidthPreferenceTests: XCTestCase {

    func testClamp_belowMin_returnsMin() {
        XCTAssertEqual(SidebarWidthPreference.clamp(50), SidebarWidthPreference.minWidth)
    }

    func testClamp_aboveMax_returnsMax() {
        XCTAssertEqual(SidebarWidthPreference.clamp(9999), SidebarWidthPreference.maxWidth)
    }

    func testClamp_withinRange_unchanged() {
        XCTAssertEqual(SidebarWidthPreference.clamp(300), 300)
    }

    func testLoad_unset_returnsDefault() {
        let defaults = makeDefaults()
        XCTAssertEqual(SidebarWidthPreference.load(defaults), SidebarWidthPreference.defaultWidth)
    }

    func testLoad_storedOutOfRange_isClamped() {
        let defaults = makeDefaults()
        defaults.set(Double(9999), forKey: "sidebarWidth")
        XCTAssertEqual(SidebarWidthPreference.load(defaults), SidebarWidthPreference.maxWidth)
    }

    func testStore_thenLoad_roundTrips() {
        let defaults = makeDefaults()
        SidebarWidthPreference.store(360, into: defaults)
        XCTAssertEqual(SidebarWidthPreference.load(defaults), 360)
    }

    func testStore_clampsBeforePersisting() {
        let defaults = makeDefaults()
        SidebarWidthPreference.store(40, into: defaults)
        XCTAssertEqual(SidebarWidthPreference.load(defaults), SidebarWidthPreference.minWidth)
    }

    /// Isolated, empty defaults so tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suite = "SidebarWidthPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
