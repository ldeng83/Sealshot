import XCTest
@testable import Sealshot

final class SliderInputFormatTests: XCTestCase {
    func testRoundsAndClampsHigh() {
        XCTAssertEqual(SliderInputFormat.clamp("99", min: 1, max: 50, fallback: 8), 50)
    }
    func testClampsLow() {
        XCTAssertEqual(SliderInputFormat.clamp("0", min: 1, max: 50, fallback: 8), 1)
    }
    func testRoundsFractional() {
        XCTAssertEqual(SliderInputFormat.clamp("12.6", min: 1, max: 50, fallback: 8), 13)
    }
    func testInRange() {
        XCTAssertEqual(SliderInputFormat.clamp("30", min: 1, max: 50, fallback: 8), 30)
    }
    func testEmptyOrNonNumericUsesFallback() {
        XCTAssertEqual(SliderInputFormat.clamp("", min: 1, max: 50, fallback: 8), 8)
        XCTAssertEqual(SliderInputFormat.clamp("abc", min: 0, max: 100, fallback: 42), 42)
    }
    func testDisplayIsIntegerString() {
        XCTAssertEqual(SliderInputFormat.display(12.6, unit: "pt"), "13")
    }
}
