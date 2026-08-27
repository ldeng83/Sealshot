import XCTest
import AppKit
import CoreGraphics
@testable import Sealshot

/// Verifies that the EXPORT render path (`render(image:annotations:crop:scale:focus:assets:)`)
/// places shadows on the correct side: positive `offset.height` casts the shadow
/// BELOW the shape (larger screen-y = further down), and negative casts it ABOVE.
///
/// NSBitmapImageRep.colorAt(x:y:) counts y from the UPPER-LEFT corner (screen
/// space / y-down), matching annotation-space y. This test exploits that
/// convention: band rows 46-64 are "below" a line drawn at annotation y=40,
/// and rows 14-32 are "above" it.
final class ShadowRenderDirectionTests: XCTestCase {

    // MARK: - Helpers

    /// White opaque 80×80 CGImage for use as the base layer.
    private func whiteBase() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        return ctx.makeImage()!
    }

    /// A horizontal .line annotation across the midline (annotation y=40, y-down from top)
    /// with a crisp (blur=0) black shadow at the given `offsetHeight`.
    /// Positive = down in screen space; negative = up.
    private func lineAnnotation(offsetHeight: CGFloat) -> Annotation {
        Annotation(
            geometry: .line(start: CGPoint(x: 15, y: 40), end: CGPoint(x: 65, y: 40)),
            style: Style(
                strokeColor: SerializableColor(.black),
                strokeWidth: 3,
                opacity: 1,
                shadow: ShadowStyle(
                    enabled: true,
                    color: SerializableColor(.black),
                    blur: 0,
                    offset: CGSize(width: 0, height: offsetHeight),
                    opacity: 1
                )
            )
        )
    }

    /// Renders a single annotation over the white base and returns a bitmap rep.
    /// colorAt(x:y:) on the returned rep uses y=0 at the top-left (screen space y-down).
    private func renderBitmap(annotation: Annotation) -> NSBitmapImageRep {
        let img = render(image: whiteBase(), annotations: [annotation], crop: nil)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            XCTFail("Could not create bitmap rep from rendered image")
            return NSBitmapImageRep()
        }
        return rep
    }

    /// Count pixels with luminance < 0.5 in the given row band (y-down from top)
    /// across all 80 columns.
    private func darkPixels(in rep: NSBitmapImageRep, rows: ClosedRange<Int>) -> Int {
        var count = 0
        for y in rows {
            for x in 0..<80 {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let lum = 0.299 * color.redComponent
                          + 0.587 * color.greenComponent
                          + 0.114 * color.blueComponent
                if lum < 0.5 { count += 1 }
            }
        }
        return count
    }

    // MARK: - Tests

    /// Positive `offset.height` (+12) must render the shadow BELOW the line.
    ///
    /// The line is at annotation y=40 (bitmap row ≈40 from top).
    /// A +12 shadow lands at annotation y=52 (bitmap row ≈52 from top).
    /// "Below" band = rows 46-64; "above" band = rows 14-32.
    func testPositiveShadowHeightRendersBelow() {
        let rep = renderBitmap(annotation: lineAnnotation(offsetHeight: 12))
        let below = darkPixels(in: rep, rows: 46...64)
        let above = darkPixels(in: rep, rows: 14...32)
        XCTAssertGreaterThan(
            below, above,
            "Export path: +12 offset.height should place the shadow BELOW the line "
            + "(dark pixels in rows 46-64 should exceed rows 14-32); "
            + "below=\(below) above=\(above)"
        )
    }

    /// Negative `offset.height` (-12) must render the shadow ABOVE the line.
    ///
    /// A -12 shadow lands at annotation y=28 (bitmap row ≈28 from top).
    /// "Above" band = rows 14-32; "below" band = rows 46-64.
    func testNegativeShadowHeightRendersAbove() {
        let rep = renderBitmap(annotation: lineAnnotation(offsetHeight: -12))
        let below = darkPixels(in: rep, rows: 46...64)
        let above = darkPixels(in: rep, rows: 14...32)
        XCTAssertGreaterThan(
            above, below,
            "Export path: -12 offset.height should place the shadow ABOVE the line "
            + "(dark pixels in rows 14-32 should exceed rows 46-64); "
            + "above=\(above) below=\(below)"
        )
    }
}
