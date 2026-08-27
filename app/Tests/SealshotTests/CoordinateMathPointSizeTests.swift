import XCTest
import CoreGraphics
@testable import Sealshot

final class CoordinateMathPointSizeTests: XCTestCase {
    func testPixelsToPointsAt2x() {
        let pts = CoordinateMath.pointSize(pixels: (width: 1920, height: 1080), scale: 2)
        XCTAssertEqual(pts.width, 960, accuracy: 0.001)
        XCTAssertEqual(pts.height, 540, accuracy: 0.001)
    }

    func testZeroScaleTreatedAsOne() {
        let pts = CoordinateMath.pointSize(pixels: (width: 300, height: 200), scale: 0)
        XCTAssertEqual(pts.width, 300, accuracy: 0.001)
        XCTAssertEqual(pts.height, 200, accuracy: 0.001)
    }
}
