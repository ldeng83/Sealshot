import XCTest
@testable import Sealshot

final class DetectionGeometryTests: XCTestCase {

    /// "abcdef" laid out at x 0…0.6, each char 0.1 wide, line at y 0.5 h 0.05.
    private func makeLine() -> RecognizedLine {
        let box = CGRect(x: 0, y: 0.5, width: 0.6, height: 0.05)
        let charBoxes = (0..<6).map {
            CGRect(x: CGFloat($0) * 0.1, y: 0.5, width: 0.1, height: 0.05)
        }
        return RecognizedLine(text: "abcdef", box: box, charBoxes: charBoxes)
    }

    // MARK: - normalizedBox

    func testNormalizedBox_unionOfRangeCharBoxes() {
        let rect = try! XCTUnwrap(DetectionGeometry.normalizedBox(for: 2..<4, in: makeLine()))
        XCTAssertEqual(rect.minX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 0.5, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 0.05, accuracy: 1e-9)
    }

    func testNormalizedBox_emptyOrOutOfBoundsRange() {
        XCTAssertNil(DetectionGeometry.normalizedBox(for: 3..<3, in: makeLine()))
        XCTAssertNil(DetectionGeometry.normalizedBox(for: 6..<9, in: makeLine()))
        // Partially out of bounds clamps to the available boxes.
        XCTAssertEqual(DetectionGeometry.normalizedBox(for: 5..<9, in: makeLine()),
                       CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05))
    }

    // MARK: - imageRect

    func testImageRect_scalesAndPads() {
        let rect = DetectionGeometry.imageRect(
            fromNormalized: CGRect(x: 0.2, y: 0.5, width: 0.2, height: 0.05),
            imageSize: CGSize(width: 1000, height: 800), padding: 4)
        XCTAssertEqual(rect, CGRect(x: 196, y: 396, width: 208, height: 48))
    }

    func testImageRect_clampsToImageBounds() {
        let rect = DetectionGeometry.imageRect(
            fromNormalized: CGRect(x: 0, y: 0.95, width: 1.0, height: 0.05),
            imageSize: CGSize(width: 1000, height: 800), padding: 6)
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.maxX, 1000)
        XCTAssertEqual(rect.maxY, 800)
        XCTAssertEqual(rect.minY, 754)
    }

    // MARK: - mergedRects

    func testMergedRects_overlappingMergeIntoUnion() {
        let merged = DetectionGeometry.mergedRects([
            CGRect(x: 0, y: 0, width: 100, height: 20),
            CGRect(x: 90, y: 0, width: 100, height: 20),
        ])
        XCTAssertEqual(merged, [CGRect(x: 0, y: 0, width: 190, height: 20)])
    }

    func testMergedRects_disjointStaySeparate() {
        let a = CGRect(x: 0, y: 0, width: 50, height: 20)
        let b = CGRect(x: 200, y: 300, width: 50, height: 20)
        XCTAssertEqual(Set(DetectionGeometry.mergedRects([a, b]).map { "\($0)" }),
                       Set([a, b].map { "\($0)" }))
    }

    func testMergedRects_chainMergesTransitively() {
        let merged = DetectionGeometry.mergedRects([
            CGRect(x: 0, y: 0, width: 60, height: 20),
            CGRect(x: 100, y: 0, width: 60, height: 20),
            CGRect(x: 50, y: 0, width: 60, height: 20),
        ])
        XCTAssertEqual(merged, [CGRect(x: 0, y: 0, width: 160, height: 20)])
    }

    // MARK: - verticalTiles

    func testVerticalTiles_shortImageSingleTile() {
        let tiles = DetectionGeometry.verticalTiles(
            for: CGSize(width: 800, height: 1500), maxTileHeight: 2000, overlap: 200)
        XCTAssertEqual(tiles, [CGRect(x: 0, y: 0, width: 800, height: 1500)])
    }

    func testVerticalTiles_tallImageCoversWithOverlap() {
        let size = CGSize(width: 800, height: 5000)
        let tiles = DetectionGeometry.verticalTiles(for: size, maxTileHeight: 2000, overlap: 200)
        XCTAssertEqual(tiles.count, 3)
        XCTAssertEqual(tiles.first?.minY, 0)
        XCTAssertEqual(tiles.last?.maxY, 5000)
        for tile in tiles {
            XCTAssertEqual(tile.width, 800)
            XCTAssertLessThanOrEqual(tile.height, 2000)
        }
        for (a, b) in zip(tiles, tiles.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.maxY - b.minY, 200, "tiles must overlap")
        }
    }

    // MARK: - dedup (overlap bands of adjacent tiles see the same text twice)

    func testDedup_sameMatchFromTwoTilesCollapses() {
        let a = Detection(category: .email, snippet: "x@y.io", confidence: 0.9,
                          rects: [CGRect(x: 100, y: 1900, width: 80, height: 18)])
        let b = Detection(category: .email, snippet: "x@y.io", confidence: 0.9,
                          rects: [CGRect(x: 101, y: 1902, width: 79, height: 17)])
        XCTAssertEqual(DetectionGeometry.dedup([a, b]).count, 1)
    }

    func testDedup_sameTextDifferentPlacesKept() {
        let a = Detection(category: .email, snippet: "x@y.io", confidence: 0.9,
                          rects: [CGRect(x: 100, y: 100, width: 80, height: 18)])
        let b = Detection(category: .email, snippet: "x@y.io", confidence: 0.9,
                          rects: [CGRect(x: 100, y: 3000, width: 80, height: 18)])
        XCTAssertEqual(DetectionGeometry.dedup([a, b]).count, 2)
    }
}
