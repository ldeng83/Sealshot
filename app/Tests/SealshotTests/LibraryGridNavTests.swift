import XCTest
@testable import Sealshot

/// Covers the pure column-count math that drives ↑/↓ row jumps in the
/// Library grid's arrow-key navigation. Tile width is user-adjustable; these
/// pin the formula at a fixed `tileWidth: 180` with the shared
/// `LibraryViewModel.gridSpacing` (22).
@MainActor
final class LibraryGridNavTests: XCTestCase {

    func testColumnCount_matchesAdaptiveLayout() {
        XCTAssertEqual(LibraryViewModel.gridSpacing, 22)
        // One tile fits below the second tile's threshold.
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: 180, tileWidth: 180), 1)
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: 381, tileWidth: 180), 1)
        // 180 + 22 + 180 = 382 → two columns become possible at width ≥ 382.
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: 382, tileWidth: 180), 2)
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: 583, tileWidth: 180), 2)
        // 382 + 22 + 180 = 584 → three columns.
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: 584, tileWidth: 180), 3)
    }

    func testColumnCount_neverBelowOne() {
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: 0, tileWidth: 180), 1)
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: -50, tileWidth: 180), 1)
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: 100, tileWidth: 180), 1)
    }
}
