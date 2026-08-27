import XCTest
@testable import Sealshot

final class LibrarySidebarWidthPreferenceTests: XCTestCase {

    func test_clamp_boundsToMinAndMax() {
        XCTAssertEqual(LibrarySidebarWidthPreference.clamp(50), LibrarySidebarWidthPreference.minWidth)
        XCTAssertEqual(LibrarySidebarWidthPreference.clamp(9999), LibrarySidebarWidthPreference.maxWidth)
        XCTAssertEqual(LibrarySidebarWidthPreference.clamp(232), 232)
    }

    func test_load_default_whenNothingStored() {
        let d = UserDefaults(suiteName: "lib-sidebar-\(UUID().uuidString)")!
        XCTAssertEqual(LibrarySidebarWidthPreference.load(d), LibrarySidebarWidthPreference.defaultWidth)
    }

    func test_store_then_load_roundTrips() {
        let d = UserDefaults(suiteName: "lib-sidebar-\(UUID().uuidString)")!
        LibrarySidebarWidthPreference.store(280, into: d)
        XCTAssertEqual(LibrarySidebarWidthPreference.load(d), 280)
    }

    func test_load_clampsStaleOutOfRangeValue() {
        let d = UserDefaults(suiteName: "lib-sidebar-\(UUID().uuidString)")!
        d.set(Double(9999), forKey: "librarySidebarWidth")
        XCTAssertEqual(LibrarySidebarWidthPreference.load(d), LibrarySidebarWidthPreference.maxWidth)
    }
}
