import XCTest
@testable import Sealshot

/// Pixel-level smoke tests for AnnotationRenderer's image-overlay arm.
/// Deterministic CGContext rasterization — no screen dependency.
final class ImageOverlayRenderTests: XCTestCase {

    /// Render a 2-annotation list (one rectangle, one image overlay with a
    /// RED 8×8 asset over a known location) onto a white 100×100 base and
    /// assert pixel correctness:
    ///   - center of the overlay rect is red-ish (r > 0.8, g < 0.2)
    ///   - top-left corner of the output is still white
    ///
    /// This pins: asset lookup, rect placement, Y-flip correctness.
    /// Written TDD — will fail (center pixel remains white) until the .image
    /// arm of render() is implemented.
    func testRender_imageOverlay_compositesProperly() throws {
        // --- Build a solid-red 8×8 CGImage asset ---
        let assetW = 8, assetH = 8
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let assetCtx = CGContext(
            data: nil, width: assetW, height: assetH,
            bitsPerComponent: 8, bytesPerRow: assetW * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { XCTFail("cannot create asset context"); return }
        assetCtx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        assetCtx.fill(CGRect(x: 0, y: 0, width: assetW, height: assetH))
        guard let redAsset = assetCtx.makeImage() else {
            XCTFail("cannot create red asset"); return
        }

        // --- Build a white 100×100 CGImage base ---
        let baseW = 100, baseH = 100
        guard let baseCtx = CGContext(
            data: nil, width: baseW, height: baseH,
            bitsPerComponent: 8, bytesPerRow: baseW * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { XCTFail("cannot create base context"); return }
        baseCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        baseCtx.fill(CGRect(x: 0, y: 0, width: baseW, height: baseH))
        guard let whiteBase = baseCtx.makeImage() else {
            XCTFail("cannot create white base"); return
        }

        // --- Annotations ---
        // Place the overlay at (10, 10)...(50, 50) in image space (1× coords).
        let overlayRect = CGRect(x: 10, y: 10, width: 40, height: 40)
        let assetID = "smoke-red"
        let imageAnnotation = Annotation(
            geometry: .image(rect: overlayRect, assetID: assetID),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0, opacity: 1.0)
        )
        let rectAnnotation = Annotation(
            geometry: .rectangle(rect: CGRect(x: 80, y: 80, width: 10, height: 10)),
            style: Style(strokeColor: SerializableColor(NSColor.blue), strokeWidth: 1)
        )

        // --- Render ---
        let assets: [String: CGImage] = [assetID: redAsset]
        let result = render(
            image: whiteBase,
            annotations: [imageAnnotation, rectAnnotation],
            crop: nil,
            assets: assets
        )

        // --- Rasterize to a CGContext for pixel inspection ---
        guard let resultCG = CGContext(
            data: nil, width: baseW, height: baseH,
            bitsPerComponent: 8, bytesPerRow: baseW * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { XCTFail("cannot create result context"); return }
        // NSImage draws flipped relative to CGContext; flip once so (0,0)=top-left
        resultCG.translateBy(x: 0, y: CGFloat(baseH))
        resultCG.scaleBy(x: 1, y: -1)
        guard let cgResult = result.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("render returned no CGImage"); return
        }
        resultCG.draw(cgResult, in: CGRect(x: 0, y: 0, width: baseW, height: baseH))

        guard let rendered = resultCG.makeImage(),
              let dataProvider = rendered.dataProvider,
              let rawData = dataProvider.data else {
            XCTFail("cannot read pixel data"); return
        }
        let bytes = CFDataGetBytePtr(rawData)!

        // Helper: read (r,g,b) at pixel (px, py) in top-left origin space.
        func pixel(_ px: Int, _ py: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let offset = (py * baseW + px) * 4
            let r = CGFloat(bytes[offset])     / 255.0
            let g = CGFloat(bytes[offset + 1]) / 255.0
            let b = CGFloat(bytes[offset + 2]) / 255.0
            return (r, g, b)
        }

        // Center of overlay rect in image space = (30, 30).
        // In render output (top-left origin), y is flipped: py = baseH - 1 - 30 = 69.
        let center = pixel(30, 69)
        XCTAssertGreaterThan(center.r, 0.8,
            "center of overlay should be red-ish (r=\(center.r), g=\(center.g), b=\(center.b))")
        XCTAssertLessThan(center.g, 0.2,
            "center of overlay should have low green (r=\(center.r), g=\(center.g), b=\(center.b))")

        // Top-left corner should still be white.
        let corner = pixel(0, 0)
        XCTAssertGreaterThan(corner.r, 0.9, "top-left corner should be white")
        XCTAssertGreaterThan(corner.g, 0.9, "top-left corner should be white")
        XCTAssertGreaterThan(corner.b, 0.9, "top-left corner should be white")
    }

    /// Rasterize a single annotation list onto a white base and return a
    /// pixel reader in top-left origin coordinates (py = baseH-1-y).
    private func rasterize(
        annotations: [Annotation],
        assets: [String: CGImage] = [:],
        base: CGImage,
        size baseW: Int
    ) throws -> (Int, Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let baseH = baseW
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let result = render(image: base, annotations: annotations, crop: nil, assets: assets)
        guard let resultCG = CGContext(
            data: nil, width: baseW, height: baseH,
            bitsPerComponent: 8, bytesPerRow: baseW * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { throw NSError(domain: "test", code: 1) }
        resultCG.translateBy(x: 0, y: CGFloat(baseH))
        resultCG.scaleBy(x: 1, y: -1)
        guard let cgResult = result.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "test", code: 2)
        }
        resultCG.draw(cgResult, in: CGRect(x: 0, y: 0, width: baseW, height: baseH))
        guard let rendered = resultCG.makeImage(),
              let dataProvider = rendered.dataProvider,
              let rawData = dataProvider.data else {
            throw NSError(domain: "test", code: 3)
        }
        // Copy pixel bytes out so the closure doesn't dangle on rawData.
        let ptr = CFDataGetBytePtr(rawData)!
        let bytes = [UInt8](UnsafeBufferPointer(start: ptr, count: baseW * baseH * 4))
        return { px, py in
            let offset = (py * baseW + px) * 4
            return (CGFloat(bytes[offset]) / 255.0,
                    CGFloat(bytes[offset + 1]) / 255.0,
                    CGFloat(bytes[offset + 2]) / 255.0)
        }
    }

    private func solidImage(_ color: CGColor, _ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// A filled red rect rotated 90° about its center lands on a rotated
    /// footprint: the center stays red, the unrotated-only region goes white,
    /// the rotated-only region becomes red.
    func testRender_rotated90Rect_paintsRotatedFootprint() throws {
        let baseW = 100
        let whiteBase = solidImage(CGColor(red: 1, green: 1, blue: 1, alpha: 1), baseW, baseW)
        // 40×10 rect centered at (50,50): (40,45,20,10).
        var rect = Annotation(
            geometry: .rectangle(rect: CGRect(x: 40, y: 45, width: 20, height: 10)),
            style: Style(strokeColor: SerializableColor(NSColor.red), strokeWidth: 0,
                         fillColor: SerializableColor(NSColor.red))
        )
        rect.transform = AnnotationTransform(rotationDegrees: 90)
        let pixel = try rasterize(annotations: [rect], base: whiteBase, size: baseW)
        // Convert image-space y to top-left raster: py = 99 - y.
        let center = pixel(50, 99 - 50)
        XCTAssertGreaterThan(center.r, 0.8, "center stays red")
        XCTAssertLessThan(center.g, 0.2, "center stays red")
        // (58,50): inside the UNrotated footprint (40..60 wide), outside rotated.
        let unrotatedOnly = pixel(58, 99 - 50)
        XCTAssertGreaterThan(unrotatedOnly.g, 0.8, "unrotated-only region is white now")
        XCTAssertGreaterThan(unrotatedOnly.b, 0.8, "unrotated-only region is white now")
        // (50,58): inside the ROTATED footprint (45..55 tall→ now 45..55 wide /
        // 40..60 tall), red.
        let rotatedOnly = pixel(50, 99 - 58)
        XCTAssertGreaterThan(rotatedOnly.r, 0.8, "rotated-only region is red")
        XCTAssertLessThan(rotatedOnly.g, 0.2, "rotated-only region is red")
    }

    /// An image overlay with a LEFT-red / RIGHT-blue asset, flipped
    /// horizontally, reads BLUE near the overlay's left edge.
    func testRender_flippedImageOverlay_mirrors() throws {
        let baseW = 100
        let whiteBase = solidImage(CGColor(red: 1, green: 1, blue: 1, alpha: 1), baseW, baseW)
        // 8×8 asset: left half red, right half blue.
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 4, y: 0, width: 4, height: 8))
        let asset = ctx.makeImage()!
        let assetID = "lr-asset"
        var overlay = Annotation(
            geometry: .image(rect: CGRect(x: 10, y: 10, width: 40, height: 40), assetID: assetID),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0, opacity: 1.0)
        )
        overlay.transform = AnnotationTransform(flipH: true)
        let pixel = try rasterize(annotations: [overlay], assets: [assetID: asset],
                                  base: whiteBase, size: baseW)
        // Near the overlay's left edge, image-space (14,30). Unflipped that
        // samples the RED left half; flipped it samples the BLUE right half.
        let left = pixel(14, 99 - 30)
        XCTAssertGreaterThan(left.b, 0.8, "left edge reads blue after flipH (r=\(left.r) g=\(left.g) b=\(left.b))")
        XCTAssertLessThan(left.r, 0.2, "left edge reads blue after flipH")
    }
}
