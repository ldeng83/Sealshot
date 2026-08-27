import XCTest
@testable import Sealshot

final class CoordinateMathTests: XCTestCase {

    // MARK: - displayLocalRect

    func testDisplayLocalRect_primaryDisplay_isIdentity() {
        let global = CGRect(x: 100, y: 200, width: 50, height: 60)
        let result = CoordinateMath.displayLocalRect(global: global, screenOrigin: .zero)
        XCTAssertEqual(result, global)
    }

    func testDisplayLocalRect_secondaryDisplayRightOfPrimary() {
        let global = CGRect(x: 2020, y: 100, width: 100, height: 100)
        let result = CoordinateMath.displayLocalRect(
            global: global,
            screenOrigin: CGPoint(x: 1920, y: 0)
        )
        XCTAssertEqual(result, CGRect(x: 100, y: 100, width: 100, height: 100))
    }

    func testDisplayLocalRect_secondaryDisplayAbovePrimary() {
        let global = CGRect(x: 50, y: 1180, width: 80, height: 40)
        let result = CoordinateMath.displayLocalRect(
            global: global,
            screenOrigin: CGPoint(x: 0, y: 1080)
        )
        XCTAssertEqual(result, CGRect(x: 50, y: 100, width: 80, height: 40))
    }

    // MARK: - flipY

    func testFlipY_rectAtBottomOfScreen() {
        let local = CGRect(x: 10, y: 0, width: 100, height: 50)
        let result = CoordinateMath.flipY(localBottomLeft: local, screenHeight: 1080)
        XCTAssertEqual(result, CGRect(x: 10, y: 1030, width: 100, height: 50))
    }

    func testFlipY_rectAtTopOfScreen() {
        let local = CGRect(x: 0, y: 1030, width: 100, height: 50)
        let result = CoordinateMath.flipY(localBottomLeft: local, screenHeight: 1080)
        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    func testFlipY_rectInMiddle() {
        let local = CGRect(x: 100, y: 500, width: 200, height: 100)
        let result = CoordinateMath.flipY(localBottomLeft: local, screenHeight: 1080)
        XCTAssertEqual(result, CGRect(x: 100, y: 480, width: 200, height: 100))
    }

    // MARK: - pixelSize

    func testPixelSize_scale1() {
        let result = CoordinateMath.pixelSize(points: CGSize(width: 100, height: 50), scale: 1.0)
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 50)
    }

    func testPixelSize_scale2() {
        let result = CoordinateMath.pixelSize(points: CGSize(width: 100, height: 50), scale: 2.0)
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 100)
    }

    func testPixelSize_scale3() {
        let result = CoordinateMath.pixelSize(points: CGSize(width: 100, height: 50), scale: 3.0)
        XCTAssertEqual(result.width, 300)
        XCTAssertEqual(result.height, 150)
    }

    func testPixelSize_fractionalPointsAtScale2_rounds() {
        let result = CoordinateMath.pixelSize(
            points: CGSize(width: 100.7, height: 50.3),
            scale: 2.0
        )
        XCTAssertEqual(result.width, 201)   // 100.7 * 2 = 201.4 → 201
        XCTAssertEqual(result.height, 101)  // 50.3 * 2 = 100.6 → 101
    }

    func testPixelSize_subPixelRegion_clampsToOne() {
        let result = CoordinateMath.pixelSize(points: CGSize(width: 0.2, height: 0.0), scale: 1.0)
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
    }

    // MARK: - snapToPixelGrid

    // A fractional `sourceRect` makes ScreenCaptureKit resample (blur) the whole
    // capture. Snapping origin and size to the device pixel grid keeps it crisp.

    func testSnapToPixelGrid_scale1_fractional_roundsToIntegerPoints() {
        let r = CoordinateMath.snapToPixelGrid(
            CGRect(x: 100.5, y: 80.5, width: 1696.3, height: 840.7), scale: 1.0)
        XCTAssertEqual(r, CGRect(x: 101, y: 81, width: 1696, height: 841))
    }

    func testSnapToPixelGrid_scale1_alreadyIntegral_unchanged() {
        let r = CGRect(x: 100, y: 80, width: 1696, height: 840)
        XCTAssertEqual(CoordinateMath.snapToPixelGrid(r, scale: 1.0), r)
    }

    func testSnapToPixelGrid_scale2_snapsToHalfPointGrid() {
        // On a 2× display the pixel grid is every 0.5 pt. 10.3pt → 20.6px → 21px
        // → 10.5pt; size 20.0 stays; this keeps origin*scale and size*scale integral.
        let r = CoordinateMath.snapToPixelGrid(
            CGRect(x: 10.3, y: 10.0, width: 20.0, height: 30.4), scale: 2.0)
        XCTAssertEqual(r.origin.x, 10.5, accuracy: 1e-9)
        XCTAssertEqual(r.origin.y, 10.0, accuracy: 1e-9)
        XCTAssertEqual(r.size.width, 20.0, accuracy: 1e-9)
        XCTAssertEqual(r.size.height, 30.5, accuracy: 1e-9)  // 30.4*2=60.8→61→30.5
    }

    func testSnapToPixelGrid_postcondition_scaledEdgesAreIntegral() {
        for scale in [CGFloat(1.0), 2.0, 3.0] {
            let r = CoordinateMath.snapToPixelGrid(
                CGRect(x: 100.5, y: 80.5, width: 1696.3, height: 840.7), scale: scale)
            for v in [r.origin.x, r.origin.y, r.size.width, r.size.height] {
                let scaled = v * scale
                XCTAssertEqual(scaled, scaled.rounded(), accuracy: 1e-6,
                               "edge \(v)*\(scale)=\(scaled) not pixel-aligned")
            }
        }
    }

    // MARK: - clampToBounds

    func testClampToBounds_fullyInside_unchanged() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
        XCTAssertEqual(CoordinateMath.clampToBounds(rect, bounds: bounds), rect)
    }

    func testClampToBounds_spillsRightAndTop_clipped() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CGRect(x: 900, y: 700, width: 300, height: 300)
        XCTAssertEqual(
            CoordinateMath.clampToBounds(rect, bounds: bounds),
            CGRect(x: 900, y: 700, width: 100, height: 100)
        )
    }

    func testClampToBounds_originBeforeBounds_clipped() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CGRect(x: -50, y: -20, width: 200, height: 100)
        XCTAssertEqual(
            CoordinateMath.clampToBounds(rect, bounds: bounds),
            CGRect(x: 0, y: 0, width: 150, height: 80)
        )
    }
}
