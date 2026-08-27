import XCTest
@testable import Sealshot

final class RecentStripCornerButtonTests: XCTestCase {

    func testScalesWithThumbHeightAtDefault() {
        // Default strip height 88 → 22pt, matching the prior fixed size.
        XCTAssertEqual(RecentThumbnailView.cornerButtonSize(forThumbHeight: 88), 22)
    }

    func testScalesProportionallyBetweenBounds() {
        // 100 × 0.25 = 25 (within the 16…28 clamp).
        XCTAssertEqual(RecentThumbnailView.cornerButtonSize(forThumbHeight: 100), 25)
    }

    func testClampsToMinimumForShortStrip() {
        // 40 × 0.25 = 10 → floored at 16 so it stays clickable.
        XCTAssertEqual(RecentThumbnailView.cornerButtonSize(forThumbHeight: 40), 16)
    }

    func testClampsToMaximumForTallStrip() {
        // 200 × 0.25 = 50 → capped at 28 so it doesn't dominate the tile.
        XCTAssertEqual(RecentThumbnailView.cornerButtonSize(forThumbHeight: 200), 28)
    }
}
