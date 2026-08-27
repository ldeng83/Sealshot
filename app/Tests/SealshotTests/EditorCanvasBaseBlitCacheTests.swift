import XCTest
import AppKit
@testable import Sealshot

/// The canvas redraws fully on every mouse event of a drag. Re-interpolating
/// the full-resolution base image to view size each tick dominates draw()
/// for large captures, so the scaled blit must be cached and only re-rendered
/// when the base, crop, or target size actually changes.
@MainActor
final class EditorCanvasBaseBlitCacheTests: XCTestCase {

    private func makeImage(_ w: Int = 200, _ h: Int = 150) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    func test_sameFrameReusesCachedBlit() {
        let base = makeImage()
        let state = EditorState(sourceImage: base, sourceURL: nil)
        let canvas = EditorCanvasView(state: state)
        let rect = CGRect(x: 16, y: 16, width: 100, height: 75)

        let first = canvas.baseBlitImage(base: base, crop: nil, contentClip: nil, baseScale: 1, drawRect: rect)
        let second = canvas.baseBlitImage(base: base, crop: nil, contentClip: nil, baseScale: 1, drawRect: rect)
        XCTAssertTrue(first === second, "identical draw params must reuse the cached image")
        XCTAssertEqual(canvas.debugBaseBlitRenderCount, 1)
    }

    func test_cropChangeInvalidatesCache() {
        let base = makeImage()
        let state = EditorState(sourceImage: base, sourceURL: nil)
        let canvas = EditorCanvasView(state: state)
        let rect = CGRect(x: 16, y: 16, width: 100, height: 75)

        _ = canvas.baseBlitImage(base: base, crop: nil, contentClip: nil, baseScale: 1, drawRect: rect)
        let crop = CGRect(x: 10, y: 10, width: 100, height: 75)
        _ = canvas.baseBlitImage(base: base, crop: crop, contentClip: nil, baseScale: 1, drawRect: rect)
        XCTAssertEqual(canvas.debugBaseBlitRenderCount, 2)
    }

    func test_sizeChangeInvalidatesCache() {
        // Zoom is now a magnification transform (the draw size stays native), so
        // a draw-size change comes only from a crop/explicit-size change and must
        // re-render the cached blit.
        let base = makeImage()
        let state = EditorState(sourceImage: base, sourceURL: nil)
        let canvas = EditorCanvasView(state: state)

        _ = canvas.baseBlitImage(base: base, crop: nil, contentClip: nil, baseScale: 1,
                                 drawRect: CGRect(x: 16, y: 16, width: 100, height: 75))
        _ = canvas.baseBlitImage(base: base, crop: nil, contentClip: nil, baseScale: 1,
                                 drawRect: CGRect(x: 16, y: 16, width: 200, height: 150))
        XCTAssertEqual(canvas.debugBaseBlitRenderCount, 2)
    }

    func test_cachedBlitMatchesCropPixels() {
        // A 2×1 image: left pixel opaque red, right pixel opaque blue. Crop to
        // the right half and blit at 1:1 — the cached image must show blue.
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 2, height: 1,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let base = ctx.makeImage()!

        let state = EditorState(sourceImage: base, sourceURL: nil)
        let canvas = EditorCanvasView(state: state)
        let img = canvas.baseBlitImage(
            base: base, crop: CGRect(x: 1, y: 0, width: 1, height: 1),
            contentClip: nil,
            baseScale: 1, drawRect: CGRect(x: 0, y: 0, width: 1, height: 1))

        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data as Data? else {
            return XCTFail("no pixels in cached blit")
        }
        // The cache renders into an RGBA (premultipliedLast) context, so the
        // first pixel is [R, G, B, A]; the cropped right half must be blue.
        let px = [UInt8](data.prefix(4))
        XCTAssertGreaterThan(px[2], px[0],
                             "cropped blit should show the blue right half, got \(px)")
    }
}
