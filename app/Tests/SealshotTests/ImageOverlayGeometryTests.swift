import XCTest
@testable import Sealshot

final class ImageOverlayGeometryTests: XCTestCase {

    // MARK: insert rect

    func testInsertRect_capsAtHalfSmallerCanvasDimension_centered() {
        let r = overlayInsertRect(imageSize: CGSize(width: 4000, height: 2000),
                                  canvas: CGSize(width: 1000, height: 800), at: nil)
        // Cap = 400 (half of 800, the smaller canvas side); 2:1 aspect.
        XCTAssertEqual(r.width, 400, accuracy: 0.5)
        XCTAssertEqual(r.height, 200, accuracy: 0.5)
        XCTAssertEqual(r.midX, 500, accuracy: 0.5)
        XCTAssertEqual(r.midY, 400, accuracy: 0.5)
    }

    func testInsertRect_smallImageKeepsNaturalSize() {
        let r = overlayInsertRect(imageSize: CGSize(width: 120, height: 90),
                                  canvas: CGSize(width: 1000, height: 800), at: nil)
        XCTAssertEqual(r.size, CGSize(width: 120, height: 90))
    }

    func testInsertRect_atPoint_clampedInsideCanvas() {
        let r = overlayInsertRect(imageSize: CGSize(width: 200, height: 200),
                                  canvas: CGSize(width: 1000, height: 800),
                                  at: CGPoint(x: 990, y: 10))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1000, height: 800).contains(r))
        XCTAssertEqual(r.maxX, 1000, accuracy: 0.5)
        XCTAssertEqual(r.minY, 0, accuracy: 0.5)
    }

    // MARK: downscale decision

    func testDownscaleTarget_overCanvas_capsToCanvas() {
        let t = overlayAssetTargetSize(imageSize: CGSize(width: 8000, height: 4000),
                                       canvasPixels: CGSize(width: 2000, height: 1500))
        XCTAssertEqual(t, CGSize(width: 2000, height: 1000))
    }

    func testDownscaleTarget_underCanvas_unchanged() {
        let t = overlayAssetTargetSize(imageSize: CGSize(width: 500, height: 300),
                                       canvasPixels: CGSize(width: 2000, height: 1500))
        XCTAssertEqual(t, CGSize(width: 500, height: 300))
    }

    // MARK: aspect-locked corner resize

    func testAspectResize_bottomRight_locksRatio() {
        let r = aspectLockedRect(from: CGRect(x: 100, y: 100, width: 200, height: 100),
                                 handle: .bottomRight,
                                 to: CGPoint(x: 500, y: 220), aspect: 2.0)
        XCTAssertEqual(r.minX, 100); XCTAssertEqual(r.minY, 100)
        XCTAssertEqual(r.width / r.height, 2.0, accuracy: 0.001)
    }

    func testAspectResize_topLeft_anchorsBottomRight() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        let r = aspectLockedRect(from: base, handle: .topLeft,
                                 to: CGPoint(x: 0, y: 0), aspect: 2.0)
        XCTAssertEqual(r.maxX, base.maxX, accuracy: 0.001)
        XCTAssertEqual(r.maxY, base.maxY, accuracy: 0.001)
        XCTAssertEqual(r.width / r.height, 2.0, accuracy: 0.001)
    }

    func testAspectResize_minimumSizeEnforced() {
        let r = aspectLockedRect(from: CGRect(x: 0, y: 0, width: 200, height: 100),
                                 handle: .bottomRight,
                                 to: CGPoint(x: 1, y: 1), aspect: 2.0)
        XCTAssertGreaterThanOrEqual(r.width, 16)
    }

    // MARK: replace re-fit

    func testReplaceRefit_keepsCenterAndArea_newAspect() {
        let old = CGRect(x: 100, y: 100, width: 200, height: 200)
        let r = replacementFitRect(current: old, newImageSize: CGSize(width: 400, height: 100))
        XCTAssertEqual(r.midX, old.midX, accuracy: 0.5)
        XCTAssertEqual(r.midY, old.midY, accuracy: 0.5)
        XCTAssertEqual(r.width / r.height, 4.0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(max(r.width, r.height), 200.01)
    }

    func testAspectResize_lockedAtMinimum_keepsRatio() {
        let r = aspectLockedRect(from: CGRect(x: 0, y: 0, width: 200, height: 100),
                                 handle: .bottomRight,
                                 to: CGPoint(x: 1, y: 1), aspect: 2.0)
        XCTAssertEqual(r.width / r.height, 2.0, accuracy: 0.001)
    }

    func testAspectResize_nonCornerHandle_returnsRectUnchanged() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(aspectLockedRect(from: base, handle: .top,
                                        to: CGPoint(x: 0, y: 0), aspect: 2.0), base)
    }

    func testInsertRect_zeroInputs_returnZero() {
        XCTAssertEqual(overlayInsertRect(imageSize: .zero,
                                         canvas: CGSize(width: 100, height: 100),
                                         at: nil), .zero)
    }

    func testReplaceRefit_zeroCurrentRect_returnsCurrent() {
        let zero = CGRect(x: 50, y: 50, width: 0, height: 0)
        XCTAssertEqual(replacementFitRect(current: zero,
                                          newImageSize: CGSize(width: 10, height: 10)), zero)
    }
}
