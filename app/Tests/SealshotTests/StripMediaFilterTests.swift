import XCTest
@testable import Sealshot

final class StripMediaFilterTests: XCTestCase {
    func test_includes() {
        XCTAssertTrue(StripMediaFilter.all.includes(isVideo: true))
        XCTAssertTrue(StripMediaFilter.all.includes(isVideo: false))
        XCTAssertTrue(StripMediaFilter.images.includes(isVideo: false))
        XCTAssertFalse(StripMediaFilter.images.includes(isVideo: true))
        XCTAssertTrue(StripMediaFilter.videos.includes(isVideo: true))
        XCTAssertFalse(StripMediaFilter.videos.includes(isVideo: false))
    }

    func test_preference_defaultsToAll_andRoundTrips() {
        let d = UserDefaults(suiteName: "StripMediaFilterTests-\(UUID().uuidString)")!
        XCTAssertEqual(StripMediaFilterPreference.load(d), .all)
        StripMediaFilterPreference.store(.videos, d)
        XCTAssertEqual(StripMediaFilterPreference.load(d), .videos)
    }
}
