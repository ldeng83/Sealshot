import XCTest
import CoreGraphics
@testable import Sealshot

final class BaseBlitPixelSizeTests: XCTestCase {

    func test_baseScaleOne_isUnchangedSourceDensity() {
        // No enhance (baseScale 1): drawRect 500pt * backing 2 = 1000px, well
        // under the 2000px native and the ceiling → 1000px (today's behavior).
        let s = EditorCanvasView.baseBlitPixelSize(
            drawRect: CGSize(width: 500, height: 300), backing: 2, baseScale: 1,
            nativePixels: CGSize(width: 2000, height: 1200))
        XCTAssertEqual(s.w, 1000)
        XCTAssertEqual(s.h, 600)
    }

    func test_upscaledEnhance_rendersAtEnhancedDensity() {
        // baseScale 4: 500*2*4 = 4000px, == native 4000 → 4000px (the extra
        // detail is now rendered, not thrown away).
        let s = EditorCanvasView.baseBlitPixelSize(
            drawRect: CGSize(width: 500, height: 300), backing: 2, baseScale: 4,
            nativePixels: CGSize(width: 4000, height: 2400))
        XCTAssertEqual(s.w, 4000)
        XCTAssertEqual(s.h, 2400)
    }

    func test_cappedToNativePixels() {
        // Density target (800) exceeds the base's own pixels (500) → cap to native.
        let s = EditorCanvasView.baseBlitPixelSize(
            drawRect: CGSize(width: 100, height: 100), backing: 2, baseScale: 4,
            nativePixels: CGSize(width: 500, height: 500))
        XCTAssertEqual(s.w, 500)
        XCTAssertEqual(s.h, 500)
    }

    func test_cappedToSafetyCeiling() {
        // Huge upscale: density target (24000) and native (16000) both exceed the
        // ceiling → clamp to maxDimension.
        let s = EditorCanvasView.baseBlitPixelSize(
            drawRect: CGSize(width: 3000, height: 3000), backing: 2, baseScale: 4,
            nativePixels: CGSize(width: 16000, height: 16000), maxDimension: 8192)
        XCTAssertEqual(s.w, 8192)
        XCTAssertEqual(s.h, 8192)
    }

    func test_neverZero() {
        let s = EditorCanvasView.baseBlitPixelSize(
            drawRect: CGSize(width: 0, height: 0), backing: 2, baseScale: 1,
            nativePixels: CGSize(width: 100, height: 100))
        XCTAssertEqual(s.w, 1)
        XCTAssertEqual(s.h, 1)
    }
}
