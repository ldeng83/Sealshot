import XCTest
import AppKit
@testable import Sealshot

/// Regression guard: `.image` annotations must preserve orientation in the
/// export render path (AnnotationRenderer). An upside-down regression would
/// be caught here immediately.
///
/// Coordinate convention notes (verified by this test's sanity step):
///   • CGContext (bottom-left): y=0 at BOTTOM; makeImage() row 0 = CG y=H-1 = visual TOP.
///   • In AnnotationRenderer's NSBitmapImageRep context (non-flipped), `flipRectY`
///     converts annotation coords (y=0 at top) → CG coords (y=0 at bottom).
///   • In the rasterize helper below, py=0 = visual BOTTOM (CG convention).
///     To map annotation y (from top) → py: py = height - 1 - annotY.
final class ImageOrientationTests: XCTestCase {

    // MARK: - Helpers

    private let cs = CGColorSpaceCreateDeviceRGB()
    private let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    /// Create a solid-colour CGImage (CG context, bottom-left).
    private func solidCGImage(width: Int, height: Int, color: CGColor) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Read raw RGBA bytes from a CGImage (row 0 = first scanline from makeImage).
    /// For images produced by CGContext.makeImage(), row 0 = visual TOP
    /// (because makeImage stores from CG y=H-1 downward).
    private func rawBytes(of image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data else { return [] }
        let ptr = CFDataGetBytePtr(data)!
        return [UInt8](UnsafeBufferPointer(start: ptr, count: image.width * image.height * 4))
    }

    /// Rasterize a rendered NSImage into a CGContext pixel buffer.
    /// Pixel convention: py = 0 is the visual BOTTOM (CG bottom-left).
    /// To convert from annotation y (y=0 at top): py = height - 1 - annotY.
    private func rasterize(_ nsImage: NSImage, width: Int, height: Int)
        -> ((_ px: Int, _ py: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat))
    {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo)!
        // Flip so NSImage draws into the context with visual-top at CG y=height.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        if let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let rendered = ctx.makeImage(), let data = rendered.dataProvider?.data else {
            return { _, _ in (0, 0, 0) }
        }
        let ptr = CFDataGetBytePtr(data)!
        let bytes = [UInt8](UnsafeBufferPointer(start: ptr, count: width * height * 4))
        return { px, py in
            let offset = (py * width + px) * 4
            return (CGFloat(bytes[offset]) / 255.0,
                    CGFloat(bytes[offset + 1]) / 255.0,
                    CGFloat(bytes[offset + 2]) / 255.0)
        }
    }

    // MARK: - Tests

    /// Render a 100×100 two-tone overlay (top half RED, bottom half BLUE) as a
    /// full-canvas `.image` annotation and assert the export preserves orientation.
    func testExport_imageAnnotation_preservesOrientation() {
        let W = 100, H = 100

        // --- Build overlay: CG y=0..H/2 (visual bottom) = BLUE,
        //                    CG y=H/2..H (visual top)    = RED.
        // After makeImage(), row 0 of CGImage data = CG y=H-1 = RED (visual top).
        guard let overlayCtx = CGContext(data: nil, width: W, height: H,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: cs, bitmapInfo: bitmapInfo) else {
            return XCTFail("overlay context")
        }
        overlayCtx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))  // BLUE at bottom
        overlayCtx.fill(CGRect(x: 0, y: 0, width: W, height: H / 2))
        overlayCtx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))  // RED at top
        overlayCtx.fill(CGRect(x: 0, y: H / 2, width: W, height: H / 2))
        guard let overlay = overlayCtx.makeImage() else { return XCTFail("overlay makeImage") }

        // --- Sanity: verify raw CGImage row 0 = RED (visual top). ---
        let raw = rawBytes(of: overlay)
        guard raw.count >= W * H * 4 else { return XCTFail("empty raw bytes") }
        let row0R = CGFloat(raw[0]) / 255.0
        let row0B = CGFloat(raw[2]) / 255.0
        XCTAssertGreaterThan(row0R, 0.9,
            "sanity: CGImage row 0 should be RED (r=\(row0R) b=\(row0B))")
        XCTAssertLessThan(row0B, 0.1,
            "sanity: CGImage row 0 should be RED (r=\(row0R) b=\(row0B))")
        let lastOff = (H - 1) * W * 4
        let lastR = CGFloat(raw[lastOff]) / 255.0
        let lastB = CGFloat(raw[lastOff + 2]) / 255.0
        XCTAssertLessThan(lastR, 0.1,
            "sanity: CGImage last row should be BLUE (r=\(lastR) b=\(lastB))")
        XCTAssertGreaterThan(lastB, 0.9,
            "sanity: CGImage last row should be BLUE (r=\(lastR) b=\(lastB))")

        // --- Base image: white 100×100. ---
        let base = solidCGImage(width: W, height: H, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))

        // --- Annotation: .image covering the full canvas. ---
        let assetID = "orientation-guard"
        let ann = Annotation(
            geometry: .image(rect: CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)),
                             assetID: assetID),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0, opacity: 1.0)
        )

        // --- Render via AnnotationRenderer (the export path). ---
        let result = render(
            image: base,
            annotations: [ann],
            crop: nil,
            scale: 1.0,
            focus: nil,
            assets: [assetID: overlay]
        )

        // --- Read back rendered pixels. ---
        // rasterize() pixel convention: py=0 = visual BOTTOM.
        // Convert annotation y (y=0 at top) → py = H - 1 - annotY.
        let pixel = rasterize(result, width: W, height: H)

        // Top quarter (annotation y=25 from top) → py = 99 - 25 = 74. Expect RED.
        let topQuarter = pixel(W / 2, H - 1 - 25)
        XCTAssertGreaterThan(topQuarter.r, 0.8,
            "export top quarter should be RED (r=\(topQuarter.r) g=\(topQuarter.g) b=\(topQuarter.b))")
        XCTAssertLessThan(topQuarter.b, 0.2,
            "export top quarter should be RED (r=\(topQuarter.r) g=\(topQuarter.g) b=\(topQuarter.b))")

        // Bottom quarter (annotation y=75 from top) → py = 99 - 75 = 24. Expect BLUE.
        let botQuarter = pixel(W / 2, H - 1 - 75)
        XCTAssertLessThan(botQuarter.r, 0.2,
            "export bottom quarter should be BLUE (r=\(botQuarter.r) g=\(botQuarter.g) b=\(botQuarter.b))")
        XCTAssertGreaterThan(botQuarter.b, 0.8,
            "export bottom quarter should be BLUE (r=\(botQuarter.r) g=\(botQuarter.g) b=\(botQuarter.b))")
    }
}
