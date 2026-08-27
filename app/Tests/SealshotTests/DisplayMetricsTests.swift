import XCTest
@testable import Sealshot

final class DisplayMetricsTests: XCTestCase {

    func testPPI_typicalRetina() {
        // 2880 px across ~286 mm ≈ 256 ppi
        let ppi = DisplayMetrics.ppi(pixelWidth: 2880, physicalWidthMM: 286.0)
        XCTAssertEqual(ppi, 256.0, accuracy: 1.0)
    }

    func testPPI_zeroPhysicalWidth_returnsZero() {
        XCTAssertEqual(DisplayMetrics.ppi(pixelWidth: 3440, physicalWidthMM: 0), 0)
    }

    func testIsLowResolution_oneXDisplay_isLow() {
        XCTAssertTrue(DisplayMetrics.isLowResolution(pointPixelScale: 1.0, ppi: 250))
    }

    func testIsLowResolution_retina_isNotLow() {
        XCTAssertFalse(DisplayMetrics.isLowResolution(pointPixelScale: 2.0, ppi: 220))
    }

    func testIsLowResolution_scaledButLowPPI_isLow() {
        XCTAssertTrue(DisplayMetrics.isLowResolution(pointPixelScale: 2.0, ppi: 100))
    }
}
