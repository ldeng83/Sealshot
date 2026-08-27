import XCTest
import AppKit
import CoreGraphics
@testable import Sealshot

/// Regression tests for export/copy COLOR fidelity. A no-op render must return
/// the source's pixel BYTES unchanged and keep its colorspace tag — the
/// text-lightening bug was `render()` drawing the display-profile-tagged
/// capture into a `.deviceRGB` bitmap rep, color-converting every pixel
/// (lightening dark glyph cores by ~5 levels) and then saving the shifted
/// values under a different profile. ScreenCaptureKit hands us raw framebuffer
/// values tagged with the capture display's profile (verified against Apple's
/// own `screencapture`, which Snagit matches byte-for-byte); the compositor
/// must preserve both the values and the tag.
@MainActor
final class RenderColorFidelityTests: XCTestCase {

    /// Gray bands of known byte values in a deliberately NON-sRGB space
    /// (Adobe RGB stands in for a display profile) — any conversion in the
    /// compositor shifts these bytes on every machine, no monitor needed.
    private static let bands: [UInt8] = [0, 38, 51, 96, 128, 192, 247, 255]

    private func bandImage(space: CFString, w: Int = 64) -> CGImage {
        let h = Self.bands.count * 4
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        for y in 0..<h {
            let v = Self.bands[y / 4]
            for x in 0..<w {
                let o = y * bytesPerRow + x * 4
                data[o] = v; data[o+1] = v; data[o+2] = v; data[o+3] = 255
            }
        }
        let cs = CGColorSpace(name: space)!
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// RAW bytes out of the rep — `colorAt` is colorspace-aware and would
    /// round-trip a conversion invisibly, hiding exactly the bug under test.
    private func rawBandBytes(_ image: NSImage) throws -> [UInt8] {
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let data = try XCTUnwrap(rep.bitmapData)
        var out: [UInt8] = []
        for (i, _) in Self.bands.enumerated() {
            let y = i * 4 + 2
            out.append(data[y * rep.bytesPerRow + 8 * (rep.bitsPerPixel / 8)])
        }
        return out
    }

    func test_noopRender_preservesSourceBytes_nonSRGBSource() throws {
        // A display-profile-tagged capture (Adobe RGB proxy): bytes must pass
        // through untouched — this is the "Snagit text looks inkier" bug.
        let composite = render(
            image: bandImage(space: CGColorSpace.adobeRGB1998), annotations: [], crop: nil)
        let got = try rawBandBytes(composite)
        for (expected, actual) in zip(Self.bands, got) {
            XCTAssertEqual(Int(actual), Int(expected),
                           "band \(expected) rendered as \(actual) — the compositor color-converted the base instead of preserving framebuffer values")
        }
    }

    func test_noopRender_preservesSourceBytes_sRGBSource() throws {
        let composite = render(
            image: bandImage(space: CGColorSpace.sRGB), annotations: [], crop: nil)
        let got = try rawBandBytes(composite)
        for (expected, actual) in zip(Self.bands, got) {
            XCTAssertEqual(Int(actual), Int(expected))
        }
    }

    /// The drag-out/export path re-decodes composite.png through ImageIO's
    /// thumbnailer — it too must not color-convert the bytes.
    func test_downsampler_preservesBytesAndTag() throws {
        let cg = bandImage(space: CGColorSpace.adobeRGB1998)
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        let img = try XCTUnwrap(downsampledImage(from: png, maxPixel: 10_000))
        var rect = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let out = try XCTUnwrap(img.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        // The PNG round-trip re-creates the space from embedded ICC data, which
        // carries no NAME — assert it hasn't been CONVERTED to sRGB instead.
        let outSpace = try XCTUnwrap(out.colorSpace, "downsampler dropped the profile")
        XCTAssertNotEqual(outSpace.name as String?, CGColorSpace.sRGB as String,
                          "downsampler converted the source profile to sRGB")
        let outRep = NSBitmapImageRep(cgImage: out)
        let data = try XCTUnwrap(outRep.bitmapData)
        // CGImage-wrapped reps can be alpha-first (ARGB) — index the red channel.
        let channel = outRep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        for (i, expected) in Self.bands.enumerated() {
            let y = i * 4 + 2
            let actual = data[y * outRep.bytesPerRow + 8 * (outRep.bitsPerPixel / 8) + channel]
            XCTAssertEqual(Int(actual), Int(expected),
                           "band \(expected) came out of the ImageIO thumbnailer as \(actual)")
        }
    }

    func test_renderOutput_keepsSourceColorSpaceTag() throws {
        let composite = render(
            image: bandImage(space: CGColorSpace.adobeRGB1998), annotations: [], crop: nil)
        let rep = try XCTUnwrap(composite.representations.first as? NSBitmapImageRep)
        let name = rep.colorSpace.cgColorSpace?.name as String? ?? "unknown"
        XCTAssertTrue(name.contains("Adobe"),
                      "composite must carry the SOURCE's colorspace tag (got \(name)) so values stay honest — mislabeling shifted values was the export bug")
    }

    // MARK: - The PNG encoder must keep the tag too

    // The compositor is covered above, but the LAST step — turning the composite
    // into file bytes — was not. `CaptureOutputWriter.encodePNG` is the single
    // choke point for every PNG the app writes (capture, export, drag-out,
    // share import, recording posters), so a regression there would relabel
    // every file at once while leaving pixels untouched: mislabelled rather
    // than degraded, and invisible on an sRGB monitor. These pin the invariant
    // the rest of this file assumes.

    func test_encodePNG_keepsANonSRGBSourceTag() throws {
        let image = bandImage(space: CGColorSpace.adobeRGB1998)
        let png = try CaptureOutputWriter.encodePNG(image)

        let src = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        // Read the embedded ICC profile, not `CGColorSpace.name`: a colorspace
        // rebuilt from a file's profile is ICC-based and has no name, so the
        // name check reported "unknown" for a PNG that was correctly tagged.
        let space = try XCTUnwrap(decoded.colorSpace)
        let name = space.name as String?
            ?? (space.copyICCData() as Data?).flatMap {
                NSColorSpace(iccProfileData: $0)?.localizedName
            }
            ?? "unknown"
        XCTAssertTrue(name.contains("Adobe"),
                      "the encoder must not relabel a display-profile capture as sRGB (got \(name))")
    }

    func test_encodePNG_preservesPixelBytes() throws {
        // Relabelling is the bug; converting would be worse. Guard both.
        let image = bandImage(space: CGColorSpace.adobeRGB1998)
        let png = try CaptureOutputWriter.encodePNG(image)

        let src = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let before = try XCTUnwrap(image.dataProvider?.data) as Data
        let after = try XCTUnwrap(decoded.dataProvider?.data) as Data
        XCTAssertEqual(before, after, "encoding must be byte-preserving")
    }
}

/// Canvas display crispness: integer upscales sample nearest (crisp pixel
/// blocks, framebuffer-faithful text); anything fractional stays smooth.
@MainActor
final class CanvasBlitInterpolationTests: XCTestCase {
    func test_integerUpscale_usesNearest() {
        XCTAssertEqual(EditorCanvasView.blitInterpolation(srcW: 723, srcH: 851, dstW: 1446, dstH: 1702), .none)
        XCTAssertEqual(EditorCanvasView.blitInterpolation(srcW: 100, srcH: 50, dstW: 300, dstH: 150), .none)
        XCTAssertEqual(EditorCanvasView.blitInterpolation(srcW: 100, srcH: 50, dstW: 100, dstH: 50), .none)
    }
    func test_fractionalOrDownscale_staysSmooth() {
        XCTAssertEqual(EditorCanvasView.blitInterpolation(srcW: 723, srcH: 851, dstW: 1229, dstH: 1447), .high)  // 1.7x
        XCTAssertEqual(EditorCanvasView.blitInterpolation(srcW: 1446, srcH: 1702, dstW: 723, dstH: 851), .high)  // downscale
        XCTAssertEqual(EditorCanvasView.blitInterpolation(srcW: 100, srcH: 50, dstW: 200, dstH: 150), .high)     // anisotropic
        XCTAssertEqual(EditorCanvasView.blitInterpolation(srcW: 0, srcH: 0, dstW: 100, dstH: 100), .high)        // degenerate
    }

    // MARK: - The GPU magnification filter follows the same rule

    // Zoom is a GPU magnification of an already-rasterised layer — the blit
    // cache doesn't key on zoom, so it never re-renders when you zoom. The
    // layer filter was pinned to `.nearest` unconditionally, which is right
    // only at integer magnification. `zoomStep` is 1.25 and applied
    // multiplicatively (1.25, 1.5625, 1.953…), so in practice zoom is almost
    // never an integer, and nearest then duplicates SOME source pixels and not
    // others — glyph stems come out uneven. This is the same trap
    // `blitInterpolation` already avoids on the CPU path; the GPU path never
    // got the rule. Worst on a 1x display, where the layer has half the linear
    // resolution and the artifact lands straight on glyph pixels.

    func test_integerMagnification_pixelDoubles() {
        XCTAssertEqual(EditorCanvasView.magnificationFilter(forZoom: 1.0), .nearest)
        XCTAssertEqual(EditorCanvasView.magnificationFilter(forZoom: 2.0), .nearest)
        XCTAssertEqual(EditorCanvasView.magnificationFilter(forZoom: 3.0), .nearest)
        XCTAssertEqual(EditorCanvasView.magnificationFilter(forZoom: 2.0005), .nearest, "float slop")
    }

    func test_fractionalMagnification_staysSmooth() {
        // Every zoom step the UI can actually produce from 100%.
        XCTAssertEqual(EditorCanvasView.magnificationFilter(forZoom: 1.25), .linear)
        XCTAssertEqual(EditorCanvasView.magnificationFilter(forZoom: 1.5625), .linear)
        XCTAssertEqual(EditorCanvasView.magnificationFilter(forZoom: 1.953125), .linear)
        XCTAssertEqual(EditorCanvasView.magnificationFilter(forZoom: 2.44140625), .linear)
    }

    func test_minification_staysSmooth() {
        // magnificationFilter is unused below 1x, but keep it deterministic
        // rather than leaving a stale .nearest on the layer.
        XCTAssertEqual(EditorCanvasView.magnificationFilter(forZoom: 0.65), .linear)
        XCTAssertEqual(EditorCanvasView.magnificationFilter(forZoom: 0.0), .linear)
    }

    // MARK: - Rasterise at the density the canvas is actually displayed at

    // No filter can fix a resolution problem. The layer rasterised at
    // `backingScaleFactor` regardless of zoom, so the GPU was stretching or
    // shrinking a texture with exactly one texel per point — at any zoom but
    // 100% every screen pixel came from a resample with nothing spare. Verified
    // by the user: at 100% (an identity transform) the canvas matches the
    // exported PNG in Preview exactly; at 94% it visibly doesn't.
    //
    // Following the zoom makes the raster match what's on screen, so Core
    // Graphics does the resample at high quality once, and the GPU transform
    // samples ~1 texel per screen pixel instead of interpolating.

    private let size = CGSize(width: 1785, height: 1100)

    func test_rasterScale_risesWhenZoomingIn() {
        XCTAssertEqual(EditorCanvasView.canvasRasterScale(backing: 1, zoom: 1, drawSize: size), 1.0)
        XCTAssertEqual(EditorCanvasView.canvasRasterScale(backing: 1, zoom: 2, drawSize: size), 2.0)
        // A Retina canvas compounds with its own backing scale.
        XCTAssertEqual(EditorCanvasView.canvasRasterScale(backing: 2, zoom: 1.25, drawSize: size),
                       2.5, accuracy: 0.0001)
    }

    /// Zooming OUT must never rasterise below native.
    ///
    /// It did, and it produced a cliff at exactly 100%: at 1.0 the blit is an
    /// identity copy (`blitInterpolation` returns `.none` for an integer
    /// upscale) and looks perfect; at 0.98 the target became 0.98 of native, so
    /// every pixel went through a Lanczos downsample and one-pixel glyph stems
    /// softened. A 2% zoom change flipped the image from pristine to blurry.
    ///
    /// Keeping full density instead means the GPU reduces from ALL the source
    /// detail — supersampling, with mipmaps — rather than us discarding detail
    /// first and displaying the remainder 1:1. It also means zooming out never
    /// re-rasterises at all, so that direction stays smooth for free.
    func test_rasterScale_neverDropsBelowNativeWhenZoomingOut() {
        XCTAssertEqual(EditorCanvasView.canvasRasterScale(backing: 1, zoom: 0.98, drawSize: size),
                       1.0, accuracy: 0.0001, "no cliff either side of 100%")
        XCTAssertEqual(EditorCanvasView.canvasRasterScale(backing: 1, zoom: 0.64, drawSize: size),
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(EditorCanvasView.canvasRasterScale(backing: 2, zoom: 0.5, drawSize: size),
                       2.0, accuracy: 0.0001, "a Retina canvas keeps its own density")
    }

    func test_rasterScale_isCappedSoDeepZoomCannotExhaustMemory() {
        // Backing store grows with the SQUARE of this, so it needs a ceiling —
        // the same 8192 budget the blit already clamps to.
        let s = EditorCanvasView.canvasRasterScale(backing: 2, zoom: 40, drawSize: size)
        XCTAssertLessThanOrEqual(size.width * s, 8192.0001, "must not exceed the pixel budget")
        XCTAssertGreaterThan(s, 1, "but must still gain density over 1x")
    }

    func test_rasterScale_neverDegenerate() {
        XCTAssertGreaterThan(EditorCanvasView.canvasRasterScale(backing: 1, zoom: 0, drawSize: size), 0)
        XCTAssertGreaterThan(
            EditorCanvasView.canvasRasterScale(backing: 1, zoom: 1, drawSize: .zero), 0)
    }
}
