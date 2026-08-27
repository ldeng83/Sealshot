import XCTest
import CoreGraphics
@testable import Sealshot

final class CropMarchingPhaseTests: XCTestCase {

    func test_halfLoopAdvancesHalfPeriod() {
        XCTAssertEqual(cropMarchingPhase(0, dt: 0.3, period: 10, loopDuration: 0.6), 5, accuracy: 0.0001)
    }

    func test_fullLoopWrapsToZero() {
        XCTAssertEqual(cropMarchingPhase(0, dt: 0.6, period: 10, loopDuration: 0.6), 0, accuracy: 0.0001)
    }

    func test_wrapsPastPeriod() {
        // 8 + 10*(0.3/0.6) = 13 → 13 mod 10 = 3
        XCTAssertEqual(cropMarchingPhase(8, dt: 0.3, period: 10, loopDuration: 0.6), 3, accuracy: 0.0001)
    }

    func test_guardsZeroPeriodOrDuration() {
        XCTAssertEqual(cropMarchingPhase(4, dt: 0.1, period: 0, loopDuration: 0.6), 4)
        XCTAssertEqual(cropMarchingPhase(4, dt: 0.1, period: 10, loopDuration: 0), 4)
    }
}
