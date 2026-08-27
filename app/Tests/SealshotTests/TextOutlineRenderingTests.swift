import XCTest
import AppKit
@testable import Sealshot

/// Outline paint order at the pixel level. The legacy single-pass renderer
/// (negative NSAttributedString strokeWidth = stroke+fill per glyph) draws a
/// CENTERED stroke whose inner half eats the glyph's own fill, and each
/// glyph's stroke paints over the previous glyph's fill where fat outlines
/// overlap. The fix is CSS `paint-order: stroke fill` semantics: one stroke
/// pass for the whole text, then the fill pass on top — outlines expand
/// strictly outward.
final class TextOutlineRenderingTests: XCTestCase {

    /// A 200pt "I" with a fat (25% of font) black outline and red fill: the
    /// stem is ~28pt wide while the centered stroke's inner half is ~25pt per
    /// edge — single-pass rendering swallows the stem entirely (center pixel
    /// black). Stroke-first + fill-on-top must leave the stem center RED.
    func testFatOutline_fillSurvivesOnTop() throws {
        var run = TextRun(text: "I", color: SerializableColor(r: 1, g: 0, b: 0, a: 1),
                          fontSize: 200, isBold: true)
        run.outlineColor = SerializableColor(r: 0, g: 0, b: 0, a: 1)
        run.outlineWidth = 25
        // Offset so the full outline fits in-image (a clipped left lobe
        // would skew the ink-span center off the stem).
        let rect = CGRect(x: 60, y: 60, width: 300, height: 300)
        let annotation = Annotation(geometry: .text(rect: rect, runs: [run]),
                                    style: Style(strokeColor: SerializableColor(.black), strokeWidth: 0))

        let base = makeWhiteImage(width: 400, height: 400)
        let out = render(image: base, annotations: [annotation], crop: nil)
        // On a row through the stem: the centered single-pass stroke's inner
        // half (~50pt per edge) swallows the ~32pt stem completely — NO red
        // pixel survives anywhere. Stroke-first + fill-on-top must leave the
        // red fill visible, with black outline pixels beside it.
        let row = 160
        var sawRed = false, sawBlack = false
        for x in 0..<400 {
            let px = pixelRGB(out, x: x, y: row)
            if px.r > 0.6 && px.g < 0.4 && px.b < 0.4 { sawRed = true }
            if px.r + px.g + px.b < 0.3 { sawBlack = true }
        }
        XCTAssertTrue(sawRed, "the red FILL must survive on top of a fat outline")
        XCTAssertTrue(sawBlack, "the black outline must still be drawn")
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

    private func pixelRGB(_ image: NSImage, x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard let rep = NSBitmapImageRep(data: image.tiffRepresentation!),
              let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (1, 1, 1) }
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

}
