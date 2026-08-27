import XCTest
@testable import Sealshot

@MainActor
final class LibraryTileSizeTests: XCTestCase {

    // MARK: snap (clamp to [min, max] then quantize to step)

    func test_snap_clampsBelowMinimum() {
        XCTAssertEqual(LibraryTileSize.snap(119), 120)
        XCTAssertEqual(LibraryTileSize.snap(0), 120)
        XCTAssertEqual(LibraryTileSize.snap(-50), 120)
    }

    func test_snap_clampsAboveMaximum() {
        XCTAssertEqual(LibraryTileSize.snap(999), 480)
        XCTAssertEqual(LibraryTileSize.snap(481), 480)
    }

    func test_snap_roundsToNearestStep() {
        XCTAssertEqual(LibraryTileSize.snap(137), 140)
        XCTAssertEqual(LibraryTileSize.snap(125), 120)
        XCTAssertEqual(LibraryTileSize.snap(180), 180)
    }

    // MARK: height (preserve historical 180→120 card aspect)

    func test_height_preservesHistoricalRatio() {
        XCTAssertEqual(LibraryTileSize.height(forWidth: 180), 120)
    }

    func test_height_scalesWithWidth() {
        XCTAssertEqual(LibraryTileSize.height(forWidth: 240), 160)
        XCTAssertEqual(LibraryTileSize.height(forWidth: 300), 200)
    }

    // MARK: gridColumnCount now keys off the chosen tile width

    func test_gridColumnCount_usesTileWidth() {
        // Larger tiles → fewer columns for the same available width.
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: 600, tileWidth: 180), 3)
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: 600, tileWidth: 300), 1)
    }

    func test_gridColumnCount_defaultsToConfiguredTileWidth() {
        // Omitting tileWidth uses LibraryTileSize.default (280).
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: 600),
                       LibraryViewModel.gridColumnCount(forWidth: 600, tileWidth: 280))
        XCTAssertEqual(LibraryViewModel.gridColumnCount(forWidth: 600, tileWidth: 280), 2)
    }
}
