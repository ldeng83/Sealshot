import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class DragPeekHintTests: XCTestCase {

    private func solid(_ size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            NSColor.systemTeal.setFill(); r.fill(); return true
        }
    }

    func test_composedImageIsTallerThanTheOriginal() {
        let original = solid(NSSize(width: 64, height: 64))
        let composed = DragPeekHint.compose(original)
        XCTAssertGreaterThan(composed.size.height, original.size.height)
    }

    /// A 64pt icon is narrower than the caption, so the canvas must widen to fit
    /// rather than clipping the text.
    func test_composedImageWidensForAWiderCaption() {
        let original = solid(NSSize(width: 16, height: 16))
        let composed = DragPeekHint.compose(original)
        XCTAssertGreaterThan(composed.size.width, original.size.width)
    }

    /// The grab point must not move. The caption sits ABOVE the thumbnail, so
    /// the frame grows UPWARD and the BOTTOM edge is the anchor — pinning the
    /// top instead would shove the thumbnail down by the caption's height.
    func test_frameGrowsUpwardAndKeepsTheBottomEdge() {
        let rect = NSRect(x: 10, y: 100, width: 64, height: 64)
        let composed = NSSize(width: 90, height: 82)
        let original = NSSize(width: 64, height: 64)
        let f = DragPeekHint.frame(forOriginal: rect, composed: composed, original: original)
        XCTAssertEqual(f.minY, rect.minY, accuracy: 0.001, "bottom edge must stay fixed")
        XCTAssertGreaterThan(f.maxY, rect.maxY, "extra height must be added ABOVE")
        XCTAssertEqual(f.height, 82, accuracy: 0.001)
        XCTAssertEqual(f.width, 90, accuracy: 0.001)
    }

    /// Widening is centred, so the thumbnail stays over the pointer.
    func test_frameWideningIsCentred() {
        let rect = NSRect(x: 10, y: 100, width: 64, height: 64)
        let f = DragPeekHint.frame(forOriginal: rect,
                                   composed: NSSize(width: 90, height: 82),
                                   original: NSSize(width: 64, height: 64))
        XCTAssertEqual(f.midX, rect.midX, accuracy: 0.001)
    }

    /// The caption has to name the control key in a form the user can act on.
    /// Asserting on the phrasing rather than one glyph, since the wording is
    /// spelled out ("ctrl ^") rather than using the ⌃ symbol alone.
    func test_textNamesTheControlKey() {
        let text = DragPeekHint.text.lowercased()
        XCTAssertTrue(text.contains("ctrl") || text.contains("⌃"),
                      "caption must name the control key, got: \(DragPeekHint.text)")
        XCTAssertTrue(text.contains("hide"),
                      "caption must say what the key does, got: \(DragPeekHint.text)")
    }

    /// The strip's tile image is built at PIXEL dimensions (CaptureThumbnail's
    /// downsampledImage), while the on-screen dragging frame is point space —
    /// the two bases genuinely differ at the real call site. `frame` must scale
    /// by ratio, not subtract raw deltas, or the returned frame balloons to the
    /// image's (much larger) size.
    func test_frameScalesByRatioWhenRectAndOriginalBasesDiffer() {
        let rect = NSRect(x: 0, y: 0, width: 156, height: 88)
        let original = NSSize(width: 720, height: 405)
        let composed = NSSize(width: 720, height: 425)
        let f = DragPeekHint.frame(forOriginal: rect, composed: composed, original: original)
        XCTAssertEqual(f.width, 156, accuracy: 0.001, "width unchanged: composed.width == original.width")
        XCTAssertEqual(f.minY, rect.minY, accuracy: 0.001, "bottom edge must stay fixed")
        XCTAssertEqual(f.height, 88 * (425.0 / 405.0), accuracy: 0.01, "height grows only proportionally")
    }

    /// A zero-size `original` must not produce NaN/infinity — fall back to `rect`.
    func test_frameWithZeroOriginalReturnsRectUnchanged() {
        let rect = NSRect(x: 10, y: 100, width: 64, height: 64)
        let f = DragPeekHint.frame(forOriginal: rect, composed: NSSize(width: 90, height: 82),
                                   original: .zero)
        XCTAssertEqual(f, rect)
    }

    /// `test_composedImageIsTallerThanTheOriginal` only checks total height —
    /// it would still pass with the layout inverted, which would break the
    /// position-preserving contract the whole feature relies on. Verify the
    /// original's pixels actually land at the BOTTOM of the canvas (the caption
    /// sits above it) and that the top band is the pill, not the original.
    ///
    /// NOTE on coordinates: `NSBitmapImageRep.colorAt(x:y:)` indexes rows
    /// TOP-DOWN, the opposite of AppKit's y-up drawing space — so `y: 1` is the
    /// visual TOP and `y: pixelsHigh - 2` is the visual BOTTOM.
    func test_composePlacesTheOriginalAtTheBottomOfTheCanvas() {
        let red = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { r in
            NSColor.red.setFill(); r.fill(); return true
        }
        let composed = DragPeekHint.compose(red)
        guard let cg = composed.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("composed image has no CGImage")
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        let midX = rep.pixelsWide / 2

        let bottomColor = rep.colorAt(x: midX, y: rep.pixelsHigh - 2)!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(bottomColor.redComponent, 0.8, "original's red should be at the BOTTOM of the canvas")
        XCTAssertLessThan(bottomColor.blueComponent, 0.2)

        let topColor = rep.colorAt(x: midX, y: 1)!.usingColorSpace(.deviceRGB)!
        XCTAssertLessThan(topColor.redComponent, 0.5, "top band is the pill, not the original's red")
    }

    /// `composed(for:in:)` must normalise a PIXEL-sized source (strip tiles are
    /// built up to 720px wide) into the FRAME's point space before composing —
    /// otherwise the pill is drawn at 720px scale and shrinks to illegibility
    /// once Cocoa stretches the image down into the ~117pt drag frame. The
    /// returned image's height must stay near frame-space (a bit over 88), not
    /// balloon toward the original's 405-pixel height, and the returned frame's
    /// width/top-edge must be unchanged from the input frame.
    func test_composedForInFrame_normalisesAMismatchedPixelSourceToFrameSpace() {
        let source = solid(NSSize(width: 720, height: 405))
        let frame = NSRect(x: 0, y: 0, width: 117, height: 88)
        let result = DragPeekHint.composed(for: source, in: frame)

        // Width is NOT asserted equal to 117: when the caption is wider than the
        // tile the drag image legitimately widens to fit it. What must hold is
        // that it never SHRINKS, and that it stays centred on the grab point.
        XCTAssertGreaterThanOrEqual(result.frame.width, 117, "must never shrink below the frame")
        XCTAssertEqual(result.frame.midX, frame.midX, accuracy: 0.001, "widening stays centred")
        XCTAssertEqual(result.frame.minY, frame.minY, accuracy: 0.001, "bottom edge unchanged")

        XCTAssertGreaterThan(result.image.size.height, 88, "canvas must be taller than the frame to fit the pill")
        XCTAssertLessThan(result.image.size.height, 405, "must be in POINT space, not the original's pixel space")

        // The point-space guarantee that makes the caption legible: the composed
        // canvas and the returned frame stay 1:1, so nothing is stretched.
        XCTAssertEqual(result.image.size.width, result.frame.width, accuracy: 0.001,
                       "canvas and frame must stay 1:1 or the caption is scaled")
    }

    /// When the source image's own size already matches the frame (the Library
    /// icon case: a 64x64 `NSImage` in a 64x64 frame), `composed(for:in:)` must
    /// behave the same as calling `compose` + `frame` directly.
    func test_composedForInFrame_matchesComposePlusFrameWhenBasesAlreadyMatch() {
        let source = solid(NSSize(width: 64, height: 64))
        let frame = NSRect(x: 0, y: 0, width: 64, height: 64)

        let result = DragPeekHint.composed(for: source, in: frame)
        let expectedImage = DragPeekHint.compose(source)
        let expectedFrame = DragPeekHint.frame(forOriginal: frame,
                                               composed: expectedImage.size,
                                               original: source.size)

        XCTAssertEqual(result.image.size, expectedImage.size)
        XCTAssertEqual(result.frame, expectedFrame)
    }

    /// A zero-sized destination frame must not be drawn into — doing so raises
    /// an uncatchable Objective-C exception (a hard crash, not a bad image).
    /// Unreachable from today's call sites, but this makes `composed(for:in:)`
    /// symmetric with `frame(forOriginal:composed:original:)`'s existing guard.
    func test_composedForInFrame_zeroSizedFrameReturnsOriginalUnchanged() {
        let source = solid(NSSize(width: 64, height: 64))
        let zeroFrame = NSRect(x: 10, y: 20, width: 0, height: 0)
        let result = DragPeekHint.composed(for: source, in: zeroFrame)
        XCTAssertEqual(result.image, source)
        XCTAssertEqual(result.frame, zeroFrame)
    }
}
