import XCTest
@testable import Sealshot

final class LibraryTileSizePreferenceTests: XCTestCase {

    func test_unset_defaultsToConfiguredDefault() {
        XCTAssertEqual(LibraryTileSizePreference.load(makeDefaults()), 280)
    }

    func test_roundTrip_snappedWidth() {
        let d = makeDefaults()
        LibraryTileSizePreference.store(240, into: d)
        XCTAssertEqual(LibraryTileSizePreference.load(d), 240)
    }

    func test_load_clampsOutOfRangeStoredValue() {
        let d = makeDefaults()
        d.set(9999.0, forKey: "libraryTileWidth")
        XCTAssertEqual(LibraryTileSizePreference.load(d), 480)
    }

    func test_store_snapsBeforePersisting() {
        let d = makeDefaults()
        LibraryTileSizePreference.store(137, into: d)
        XCTAssertEqual(LibraryTileSizePreference.load(d), 140)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "LibraryTileSizePreferenceTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
}
