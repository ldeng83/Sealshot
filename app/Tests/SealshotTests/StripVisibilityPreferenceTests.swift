import XCTest
@testable import Sealshot

final class StripVisibilityPreferenceTests: XCTestCase {

    func testIsHidden_unset_defaultsToVisible() {
        let defaults = makeDefaults()
        XCTAssertFalse(StripVisibilityPreference.isHidden(defaults))
    }

    func testStoreTrue_thenLoad_isHidden() {
        let defaults = makeDefaults()
        StripVisibilityPreference.store(true, into: defaults)
        XCTAssertTrue(StripVisibilityPreference.isHidden(defaults))
    }

    func testStoreFalse_thenLoad_isVisible() {
        let defaults = makeDefaults()
        StripVisibilityPreference.store(true, into: defaults)
        StripVisibilityPreference.store(false, into: defaults)
        XCTAssertFalse(StripVisibilityPreference.isHidden(defaults))
    }

    /// Isolated, empty defaults so tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suite = "StripVisibilityPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
