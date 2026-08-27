import XCTest
@testable import Sealshot

final class EnhanceGeometryTests: XCTestCase {

    func testTiles_singleTileWhenImageFits() {
        let t = EnhanceGeometry.tiles(imageWidth: 256, imageHeight: 256, tile: 256)
        XCTAssertEqual(t, [CGRect(x: 0, y: 0, width: 256, height: 256)])
    }

    func testTiles_partialEdgeTiles() {
        let t = EnhanceGeometry.tiles(imageWidth: 300, imageHeight: 200, tile: 256)
        XCTAssertEqual(t, [
            CGRect(x: 0, y: 0, width: 256, height: 200),
            CGRect(x: 256, y: 0, width: 44, height: 200),
        ])
    }

    func testTiles_gridCoversEverything() {
        let t = EnhanceGeometry.tiles(imageWidth: 513, imageHeight: 300, tile: 256)
        XCTAssertEqual(t.count, 6) // 3 cols (256,256,1) x 2 rows (256,44)
        XCTAssertEqual(t.last, CGRect(x: 512, y: 256, width: 1, height: 44))
    }

    func testTiles_emptyForZeroSize() {
        XCTAssertTrue(EnhanceGeometry.tiles(imageWidth: 0, imageHeight: 10, tile: 256).isEmpty)
    }

    func testOutputSize_doublesAtScale2() {
        XCTAssertEqual(
            EnhanceGeometry.outputSize(imageWidth: 100, imageHeight: 80, outputScale: 2),
            CGSize(width: 200, height: 160)
        )
    }
}
