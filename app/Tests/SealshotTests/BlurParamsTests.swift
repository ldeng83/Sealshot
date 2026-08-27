import XCTest
@testable import Sealshot

final class BlurParamsTests: XCTestCase {

    func testPixelateScale_endpointsAndMidpoint() {
        XCTAssertEqual(BlurParams.pixelateScale(forStrength: 0), 4, accuracy: 0.001)
        XCTAssertEqual(BlurParams.pixelateScale(forStrength: 0.5), 22, accuracy: 0.001)
        XCTAssertEqual(BlurParams.pixelateScale(forStrength: 1), 40, accuracy: 0.001)
    }

    func testGaussianRadius_endpointsAndMidpoint() {
        XCTAssertEqual(BlurParams.gaussianRadius(forStrength: 0), 2, accuracy: 0.001)
        XCTAssertEqual(BlurParams.gaussianRadius(forStrength: 0.5), 17, accuracy: 0.001)
        XCTAssertEqual(BlurParams.gaussianRadius(forStrength: 1), 32, accuracy: 0.001)
    }

    func testStrengthIsClampedOutOfRange() {
        XCTAssertEqual(BlurParams.pixelateScale(forStrength: -5), 4, accuracy: 0.001)
        XCTAssertEqual(BlurParams.pixelateScale(forStrength: 9), 40, accuracy: 0.001)
        XCTAssertEqual(BlurParams.gaussianRadius(forStrength: -5), 2, accuracy: 0.001)
        XCTAssertEqual(BlurParams.gaussianRadius(forStrength: 9), 32, accuracy: 0.001)
    }

    func testBoundingRect_freehandInflatesByHalfWidth() {
        let region = BlurRegion.freehand(points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 20)], width: 8)
        // raw bounds (10,10)-(30,20) inflated by 4 on every side
        XCTAssertEqual(region.boundingRect, CGRect(x: 6, y: 6, width: 28, height: 18))
    }

    func testBoundingRect_rectIsStandardized() {
        let region = BlurRegion.rect(CGRect(x: 30, y: 30, width: -20, height: -10))
        XCTAssertEqual(region.boundingRect, CGRect(x: 10, y: 20, width: 20, height: 10))
    }

    func testOffsetBy_translatesEachCase() {
        XCTAssertEqual(BlurRegion.rect(CGRect(x: 1, y: 2, width: 3, height: 4)).offsetBy(dx: 5, dy: 6),
                       .rect(CGRect(x: 6, y: 8, width: 3, height: 4)))
        XCTAssertEqual(BlurRegion.freehand(points: [CGPoint(x: 0, y: 0)], width: 2).offsetBy(dx: 5, dy: 6),
                       .freehand(points: [CGPoint(x: 5, y: 6)], width: 2))
    }
}
