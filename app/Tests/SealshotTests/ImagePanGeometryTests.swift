import XCTest
@testable import Sealshot

final class ImagePanGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)

    func test_pannedFocus_movesOppositeToDrag() {
        // Drag the image right+down by (10, 5) → focus shifts left+up by the same.
        let start = CGRect(x: 40, y: 30, width: 20, height: 20)
        let r = pannedFocus(start: start, dragDeltaImage: CGPoint(x: 10, y: 5), within: bounds)
        XCTAssertEqual(r, CGRect(x: 30, y: 25, width: 20, height: 20))
    }

    func test_pannedFocus_zeroDeltaIsIdentity() {
        let start = CGRect(x: 40, y: 30, width: 20, height: 20)
        XCTAssertEqual(pannedFocus(start: start, dragDeltaImage: .zero, within: bounds), start)
    }

    func test_pannedFocus_clampsAtLeftTopEdge() {
        // Big positive drag pushes focus toward the origin; it pins at (0,0).
        let start = CGRect(x: 5, y: 5, width: 20, height: 20)
        let r = pannedFocus(start: start, dragDeltaImage: CGPoint(x: 999, y: 999), within: bounds)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    func test_pannedFocus_clampsAtRightBottomEdge() {
        let start = CGRect(x: 75, y: 55, width: 20, height: 20)
        let r = pannedFocus(start: start, dragDeltaImage: CGPoint(x: -999, y: -999), within: bounds)
        XCTAssertEqual(r, CGRect(x: 80, y: 60, width: 20, height: 20))  // maxX=100, maxY=80
    }

    func test_threshold() {
        XCTAssertFalse(panDragExceedsThreshold(CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), threshold: 3))
        XCTAssertTrue(panDragExceedsThreshold(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 4), threshold: 3))
    }
}
