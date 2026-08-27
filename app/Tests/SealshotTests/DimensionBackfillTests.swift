import XCTest
@testable import Sealshot

final class DimensionBackfillTests: XCTestCase {
    func testSealRowMissingDimensionsIsBackfilled() {
        XCTAssertTrue(needsDimensionBackfill(isSeal: true, width: 0))
    }
    func testSealRowWithDimensionsIsNot() {
        XCTAssertFalse(needsDimensionBackfill(isSeal: true, width: 2560))
    }
    func testNonSealRowIsNever() {
        XCTAssertFalse(needsDimensionBackfill(isSeal: false, width: 0))
    }
}
