import XCTest
@testable import Sealshot

// DeveloperToolsSupport also exports a LibraryItem; pin to ours.
private typealias LibraryItem = Sealshot.LibraryItem

final class LibraryInfoAggregateTests: XCTestCase {
    private func item(_ size: Int64, video: Bool, day: Int) -> LibraryItem {
        LibraryItem(url: URL(fileURLWithPath: "/tmp/\(day).seal"),
                    modified: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
                    displayName: "\(day)", fileSize: size, category: nil,
                    isFavorite: false, status: .new, matchSnippet: nil,
                    isVideo: video, durationSeconds: video ? 5 : nil, collectionIDs: [])
    }

    func testCountsSizeAndRange() {
        let items = [item(100, video: false, day: 1),
                     item(200, video: true, day: 3),
                     item(300, video: false, day: 2)]
        let a = LibraryInfoAggregate.make(visible: items, sectionTotal: 10, isNarrowed: true)
        XCTAssertEqual(a.visibleCount, 3)
        XCTAssertEqual(a.imageCount, 2)
        XCTAssertEqual(a.videoCount, 1)
        XCTAssertEqual(a.totalSize, 600)
        XCTAssertEqual(a.oldest, Date(timeIntervalSince1970: 86_400))
        XCTAssertEqual(a.newest, Date(timeIntervalSince1970: 3 * 86_400))
        XCTAssertEqual(a.sectionTotal, 10)
        XCTAssertTrue(a.isNarrowed)
    }

    func testEmpty() {
        let a = LibraryInfoAggregate.make(visible: [], sectionTotal: 0, isNarrowed: false)
        XCTAssertEqual(a.visibleCount, 0)
        XCTAssertNil(a.oldest)
        XCTAssertNil(a.newest)
        XCTAssertFalse(a.isNarrowed)
    }
}
