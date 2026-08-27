import XCTest
@testable import Sealshot

final class CaptureStatusTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(CaptureStatus.new.displayLabel, "New")
        XCTAssertEqual(CaptureStatus.reviewed.displayLabel, "Reviewed")
        XCTAssertEqual(CaptureStatus.archived.displayLabel, "Archived")
    }
    func testRawValuesStable() {
        XCTAssertEqual(CaptureStatus.reviewed.rawValue, "reviewed")
        XCTAssertEqual(CaptureStatus.allCases.count, 3)
    }
}
