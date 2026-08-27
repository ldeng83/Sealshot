import XCTest
@testable import Sealshot

final class FocusPreviewIndicatorTests: XCTestCase {

    func test_nilFocus_returnsNil() {
        XCTAssertNil(FocusPreviewIndicator.normalizedFocus(
            focus: nil, visibleSize: CGSize(width: 100, height: 100)))
    }

    func test_subRegion_normalizesTopLeftOrigin() {
        let n = FocusPreviewIndicator.normalizedFocus(
            focus: CGRect(x: 25, y: 50, width: 50, height: 25),
            visibleSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(n, CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
    }

    func test_normalizesAgainstCropSize() {
        // Focus lives in visible (post-crop) coords, so the crop size is the
        // reference — a half-width focus on an 800-wide crop is 0.5.
        let n = FocusPreviewIndicator.normalizedFocus(
            focus: CGRect(x: 0, y: 0, width: 400, height: 300),
            visibleSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(n, CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
    }

    func test_fullFrameFocus_returnsNil() {
        // Focus covering the whole image adds nothing → no indicator.
        XCTAssertNil(FocusPreviewIndicator.normalizedFocus(
            focus: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleSize: CGSize(width: 1000, height: 800)))
        // ≥99% on both axes also counts as full-frame.
        XCTAssertNil(FocusPreviewIndicator.normalizedFocus(
            focus: CGRect(x: 0, y: 0, width: 995, height: 992),
            visibleSize: CGSize(width: 1000, height: 1000)))
    }

    func test_narrowStripe_isKeptEvenIfOneAxisFull() {
        // A full-width but short band is a real focus region → keep it.
        let n = FocusPreviewIndicator.normalizedFocus(
            focus: CGRect(x: 0, y: 400, width: 1000, height: 100),
            visibleSize: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(n?.height, 0.1)
        XCTAssertEqual(n?.width, 1.0)
    }

    func test_degenerateAndZeroSize_returnNil() {
        XCTAssertNil(FocusPreviewIndicator.normalizedFocus(
            focus: CGRect(x: 0, y: 0, width: 0, height: 50),
            visibleSize: CGSize(width: 100, height: 100)))
        XCTAssertNil(FocusPreviewIndicator.normalizedFocus(
            focus: CGRect(x: 10, y: 10, width: 20, height: 20),
            visibleSize: .zero))
    }
}
