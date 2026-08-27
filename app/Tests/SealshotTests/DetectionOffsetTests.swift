import XCTest
@testable import Sealshot

final class DetectionOffsetTests: XCTestCase {
    func testOffsetShiftsAllRects_preservesIdentity() {
        let d = Detection(category: .contextual, snippet: "x", confidence: 0.9,
                          rects: [CGRect(x: 1, y: 2, width: 3, height: 4),
                                  CGRect(x: 5, y: 6, width: 7, height: 8)])
        let moved = d.offsetBy(dx: 10, dy: 20)
        XCTAssertEqual(moved.rects, [CGRect(x: 11, y: 22, width: 3, height: 4),
                                     CGRect(x: 15, y: 26, width: 7, height: 8)])
        XCTAssertEqual(moved.id, d.id)
        XCTAssertEqual(moved.snippet, "x")
    }

    func testZeroOffset_returnsSelfUnchanged() {
        let d = Detection(category: .contextual, snippet: "y", confidence: 0.5,
                          rects: [CGRect(x: 1, y: 1, width: 2, height: 2)])
        XCTAssertEqual(d.offsetBy(dx: 0, dy: 0), d)
    }
}
