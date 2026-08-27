import XCTest
@testable import Sealshot

final class ExtractionStageTests: XCTestCase {
    func test_labelsNonEmptyAndOrdered() {
        XCTAssertEqual(ExtractionStage.allCases.first, .reading)
        XCTAssertEqual(ExtractionStage.allCases.last, .composing)
        for s in ExtractionStage.allCases { XCTAssertFalse(s.label.isEmpty) }
    }

    func test_fractionMonotonicWithinUnitRange() {
        let f = ExtractionStage.allCases.map(\.fraction)
        XCTAssertEqual(f, f.sorted())
        XCTAssertGreaterThanOrEqual(f.first ?? -1, 0)
        XCTAssertLessThanOrEqual(f.last ?? 2, 1)
    }
}
