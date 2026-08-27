import XCTest
@testable import Sealshot

final class VideoZoomMathTests: XCTestCase {
    func testFitCapsAtActualSizeForSmallVideo() {
        // 640×360 video in a 1280×800 viewport: fit would be 2.0, capped at 1.0.
        XCTAssertEqual(VideoZoomMath.fitZoom(videoSize: CGSize(width: 640, height: 360),
                                             viewportSize: CGSize(width: 1280, height: 800)), 1.0)
    }
    func testFitBelowOneForLargeVideo() {
        // 3840×2160 in 1280×720 → 1/3 on both axes.
        XCTAssertEqual(VideoZoomMath.fitZoom(videoSize: CGSize(width: 3840, height: 2160),
                                             viewportSize: CGSize(width: 1280, height: 720)),
                       1.0 / 3.0, accuracy: 0.0001)
    }
    func testFitPicksLimitingAxis() {
        // Very wide video: width is the limiting axis.
        XCTAssertEqual(VideoZoomMath.fitZoom(videoSize: CGSize(width: 4000, height: 500),
                                             viewportSize: CGSize(width: 1000, height: 1000)),
                       0.25, accuracy: 0.0001)
    }
    func testDegenerateSizesFallBackToOne() {
        XCTAssertEqual(VideoZoomMath.fitZoom(videoSize: .zero,
                                             viewportSize: CGSize(width: 100, height: 100)), 1.0)
        XCTAssertEqual(VideoZoomMath.fitZoom(videoSize: CGSize(width: 100, height: 100),
                                             viewportSize: .zero), 1.0)
    }
    func testClampFloorsAtFitAndCeilsAtMax() {
        XCTAssertEqual(VideoZoomMath.clamp(0.1, fit: 0.5), 0.5)     // below fit → fit
        XCTAssertEqual(VideoZoomMath.clamp(3.0, fit: 0.5), 3.0)     // in range → unchanged
        XCTAssertEqual(VideoZoomMath.clamp(20.0, fit: 0.5), 8.0)    // above max → 8
    }
    func testZoomStepIsQuarterUp() {
        XCTAssertEqual(VideoZoomMath.zoomStep, 1.25)
        XCTAssertEqual(VideoZoomMath.maxZoom, 8.0)
    }
}
