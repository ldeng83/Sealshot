import XCTest
import CoreGraphics
@testable import Sealshot

final class ReadingOrderSortedTests: XCTestCase {
    private func det(_ snippet: String, _ rects: [CGRect]) -> Detection {
        Detection(category: .contextual, snippet: snippet, confidence: 0.5, rects: rects)
    }
    private func r(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat = 20) -> CGRect {
        CGRect(x: x, y: y, width: 30, height: h)
    }
    private func order(_ ds: [Detection]) -> [String] {
        EditorState.readingOrderSorted(ds).map(\.snippet)
    }

    func test_topToBottom() {
        let a = det("bottom", [r(0, 300)]), b = det("top", [r(0, 100)]), c = det("mid", [r(0, 200)])
        XCTAssertEqual(order([a, b, c]), ["top", "mid", "bottom"])
    }
    func test_sameRowLeftToRight() {
        // Within a median-height band, order by minX even if the left one's minY is lower.
        let left = det("left", [r(10, 98)]), right = det("right", [r(50, 100)])
        XCTAssertEqual(order([right, left]), ["left", "right"])
    }
    func test_rowDominatesOverX() {
        let highRight = det("highRight", [r(500, 100)]), lowLeft = det("lowLeft", [r(10, 300)])
        XCTAssertEqual(order([lowLeft, highRight]), ["highRight", "lowLeft"])
    }
    func test_multiRectSortsByTopmost() {
        let multi = det("multi", [r(0, 200), r(0, 50)])   // bbox top = 50
        let single = det("single", [r(0, 100)])
        XCTAssertEqual(order([single, multi]), ["multi", "single"])
    }
    func test_emptyRectsSortLast() {
        let none = det("none", []), positioned = det("pos", [r(0, 100)])
        XCTAssertEqual(order([none, positioned]), ["pos", "none"])
    }
}
