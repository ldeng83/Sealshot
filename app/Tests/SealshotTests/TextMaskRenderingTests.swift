import XCTest
import AppKit
@testable import Sealshot

/// Proves the text mask model at the pixel level: a shrunk box (mask) with a
/// stored `textLayoutWidth` wider than the box lays text out at that wider
/// width — producing ONE long row — and clips it to the box rect, rather than
/// re-wrapping the text to the box's narrow width.
final class TextMaskRenderingTests: XCTestCase {
    func testShrunkMask_doesNotRewrap() throws {
        var style = Style(strokeColor: SerializableColor(.black), strokeWidth: 0, fontSize: 24)
        style.textLayoutWidth = 400
        let runs = [TextRun(text: "IIII IIII IIII IIII", color: SerializableColor(.black),
                            fontSize: 24, isBold: false)]
        let lineH = textBoxHeight(runs: runs, width: 10_000)
        let rect = CGRect(x: 0, y: 0, width: 40, height: lineH * 4)   // tall, narrow mask
        let annotation = Annotation(geometry: .text(rect: rect, runs: runs), style: style)

        let base = makeWhiteImage(width: 500, height: 200)
        let out = render(image: base, annotations: [annotation], crop: nil)

        // Row 2 (still inside the tall mask, but below line 1): a re-wrapped
        // renderer paints glyphs here (it wraps "IIII IIII IIII IIII" at the
        // 40pt box width into 4 lines); the mask model lays out at the wider
        // 400pt `textLayoutWidth` — ONE line — so this stays background.
        let belowLine1 = pixelGray(out, x: 8, y: Int(lineH) + 12)
        XCTAssertGreaterThan(belowLine1, 240, "no re-wrapped glyphs below the first row")
        // Row 1, x=70: within the natural (unwrapped) single-line text width
        // at 400pt layout, but past the 40pt box — must stay clipped.
        let outside = pixelGray(out, x: 70, y: 14)
        XCTAssertGreaterThan(outside, 240, "text beyond the mask must be hidden")
    }

    /// Legacy annotations (no stored `textLayoutWidth`) must render exactly as
    /// before: layout width == rect.width, so the new clip is a no-op and text
    /// still wraps normally inside the box.
    func testLegacyAnnotation_noLayoutWidth_wrapsAtRectWidth() throws {
        let style = Style(strokeColor: SerializableColor(.black), strokeWidth: 0, fontSize: 24)
        let runs = [TextRun(text: "IIII IIII IIII IIII", color: SerializableColor(.black),
                            fontSize: 24, isBold: false)]
        // Text wraps within the box's H padding, so the box height that fits it
        // is measured at width − 2·padding.
        let narrowWrapHeight = textBoxHeight(runs: runs, width: 40 - 2 * textBoxHPadding)
        let rect = CGRect(x: 0, y: 0, width: 40, height: narrowWrapHeight)
        let annotation = Annotation(geometry: .text(rect: rect, runs: runs), style: style)

        let base = makeWhiteImage(width: 500, height: 200)
        let out = render(image: base, annotations: [annotation], crop: nil)

        // With no override, text wraps within the narrow rect to fill it, so
        // glyphs DO appear on the last line near the bottom of the box (unlike
        // the mask case above, which has exactly one line). Scan the row (text is
        // inset by the box's H padding, and exact glyph x depends on wrapping).
        let lastLineY = Int(narrowWrapHeight) - 10
        let anyGlyphOnLastLine = (1..<40).contains { pixelGray(out, x: $0, y: lastLineY) < 240 }
        XCTAssertTrue(anyGlyphOnLastLine, "legacy text still wraps to fill the box")
    }

    /// The masked layout rect anchors to the box edge the text aligns to, so
    /// right/center-aligned text pins to the box's right/center edge (extending
    /// LEFT into empty space) instead of overflowing past the right edge.
    func testTextLayoutOriginX_anchorsByAlignment() {
        // Box [10, 110] (width 100), layout narrower than the box.
        XCTAssertEqual(textLayoutOriginX(alignment: .left, boxMinX: 10, boxMaxX: 110, layoutWidth: 40), 10)
        XCTAssertEqual(textLayoutOriginX(alignment: .right, boxMinX: 10, boxMaxX: 110, layoutWidth: 40), 70)
        XCTAssertEqual(textLayoutOriginX(alignment: .center, boxMinX: 10, boxMaxX: 110, layoutWidth: 40), 40)
        // Masked box: layout WIDER than the box. Right-aligned keeps the right
        // edge on the box (110) and extends left (origin below boxMinX) so the
        // text uses the empty left space instead of clipping on the right.
        XCTAssertEqual(textLayoutOriginX(alignment: .right, boxMinX: 10, boxMaxX: 110, layoutWidth: 200), -90)
        XCTAssertEqual(textLayoutOriginX(alignment: .left, boxMinX: 10, boxMaxX: 110, layoutWidth: 200), 10)
    }

    // MARK: - helpers

    private func makeWhiteImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Grayscale-ish brightness (0-255) of the pixel at `(x, y)` in `image`.
    /// `NSBitmapImageRep.colorAt(x:y:)` counts y=0 from the TOP-left (screen
    /// space / y-down) — same convention `ShadowRenderDirectionTests` uses —
    /// which matches annotation-space y directly, so no flip is needed here.
    private func pixelGray(_ image: NSImage, x: Int, y: Int) -> Int {
        guard let rep = NSBitmapImageRep(data: image.tiffRepresentation!) else { return 0 }
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 255 }
        let gray = (c.redComponent + c.greenComponent + c.blueComponent) / 3
        return Int(gray * 255)
    }
}
