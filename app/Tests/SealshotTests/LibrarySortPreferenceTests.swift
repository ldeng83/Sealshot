import XCTest
@testable import Sealshot

final class LibrarySortPreferenceTests: XCTestCase {

    func test_unset_defaultsToDateDescending() {
        XCTAssertEqual(LibrarySortPreference.load(makeDefaults()), .default)
    }

    func test_roundTrip_field_and_direction() {
        let d = makeDefaults()
        LibrarySortPreference.store(.init(field: .name, direction: .ascending), into: d)
        XCTAssertEqual(LibrarySortPreference.load(d), .init(field: .name, direction: .ascending))
    }

    func test_roundTrip_sizeDescending() {
        let d = makeDefaults()
        LibrarySortPreference.store(.init(field: .size, direction: .descending), into: d)
        XCTAssertEqual(LibrarySortPreference.load(d), .init(field: .size, direction: .descending))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "LibrarySortPreferenceTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
}
