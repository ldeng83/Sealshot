import XCTest
@testable import Sealshot

final class LibraryFileTypeFilterTests: XCTestCase {
    func test_all_matchesBoth() {
        XCTAssertTrue(LibraryFileTypeFilter.all.matches(isVideo: true))
        XCTAssertTrue(LibraryFileTypeFilter.all.matches(isVideo: false))
    }
    func test_images_onlyNonVideo() {
        XCTAssertTrue(LibraryFileTypeFilter.images.matches(isVideo: false))
        XCTAssertFalse(LibraryFileTypeFilter.images.matches(isVideo: true))
    }
    func test_videos_onlyVideo() {
        XCTAssertTrue(LibraryFileTypeFilter.videos.matches(isVideo: true))
        XCTAssertFalse(LibraryFileTypeFilter.videos.matches(isVideo: false))
    }
}
