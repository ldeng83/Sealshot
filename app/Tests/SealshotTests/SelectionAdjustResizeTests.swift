import XCTest
import CoreGraphics
@testable import Sealshot

final class SelectionAdjustResizeTests: XCTestCase {
    // Screen bounds 0,0 … 2000×1200 (points). scale 2 → pixels are 2× points.
    private let bounds = CGRect(x: 0, y: 0, width: 2000, height: 1200)

    func testResizeKeepsTopLeftAnchor() {
        // rect top-left at (100, 1100) [minX, maxY]; 200×100 pts.
        let rect = CGRect(x: 100, y: 1000, width: 200, height: 100)
        // Ask for 600×400 px at 2× → 300×200 pts.
        let out = SelectionAdjust.resized(rect, toPixelSize: (600, 400), scale: 2,
                                          in: bounds, minSize: 20)
        XCTAssertEqual(out.minX, 100, accuracy: 0.001)      // left fixed
        XCTAssertEqual(out.maxY, 1100, accuracy: 0.001)     // top fixed
        XCTAssertEqual(out.width, 300, accuracy: 0.001)
        XCTAssertEqual(out.height, 200, accuracy: 0.001)
    }

    func testClampsToBounds() {
        let rect = CGRect(x: 1800, y: 100, width: 100, height: 100) // top-left (1800,200)
        // 1000 px / 2 = 500 pts wide, but only 200 pts to the right edge.
        let out = SelectionAdjust.resized(rect, toPixelSize: (1000, 200), scale: 2,
                                          in: bounds, minSize: 20)
        XCTAssertEqual(out.maxX, 2000, accuracy: 0.001)     // clamped to right edge
        XCTAssertEqual(out.width, 200, accuracy: 0.001)
    }

    func testFloorsAtMinSize() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let out = SelectionAdjust.resized(rect, toPixelSize: (2, 2), scale: 2,
                                          in: bounds, minSize: 20)
        XCTAssertEqual(out.width, 20, accuracy: 0.001)
        XCTAssertEqual(out.height, 20, accuracy: 0.001)
    }
}
