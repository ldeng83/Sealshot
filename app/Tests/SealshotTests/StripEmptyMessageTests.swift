import XCTest
@testable import Sealshot

final class StripEmptyMessageTests: XCTestCase {

    func test_noMessageWhileTilesAreShowing() {
        XCTAssertNil(StripEmptyMessage.text(displayedCount: 3, totalCount: 3, filter: .all))
        XCTAssertNil(StripEmptyMessage.text(displayedCount: 1, totalCount: 9, filter: .images))
    }

    func test_trulyEmptyMatchesTheLibraryWording() {
        // Same string the Library grid shows, so the two surfaces read alike.
        XCTAssertEqual(StripEmptyMessage.text(displayedCount: 0, totalCount: 0, filter: .all),
                       "No captures here yet.")
    }

    func test_filteredToEmptyExplainsTheFilter() {
        // Items DO exist — saying "no captures here yet" would be a lie and
        // would hide the fact that a filter is on.
        XCTAssertEqual(StripEmptyMessage.text(displayedCount: 0, totalCount: 4, filter: .images),
                       "No images.")
        XCTAssertEqual(StripEmptyMessage.text(displayedCount: 0, totalCount: 4, filter: .videos),
                       "No videos.")
    }

    func test_emptyUnderTheAllFilterFallsBackToTheEmptyWording() {
        // Not reachable in practice (nothing is filtered out under .all), but
        // the message must never come back nil while the strip shows nothing.
        XCTAssertEqual(StripEmptyMessage.text(displayedCount: 0, totalCount: 4, filter: .all),
                       "No captures here yet.")
    }
}
