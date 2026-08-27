import XCTest
import AppKit
@testable import Sealshot

/// A solid block-out fill ignores the sampling "strength" but its slider now
/// means opacity: the rendered fill's alpha must track `strength` (0 = clear,
/// 1 = fully opaque) so the Opacity control actually does something.
@MainActor
final class BlurSolidOpacityTests: XCTestCase {

    private func whiteSource(_ w: Int = 24, _ h: Int = 24) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Alpha (0…1) of the center pixel of `cg`.
    private func centerAlpha(_ cg: CGImage) -> CGFloat {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = ((h / 2) * w + (w / 2)) * 4
        return CGFloat(px[i + 3]) / 255.0
    }

    private func solidFill(strength: Double) -> CGImage {
        let region = BlurRegion.rect(CGRect(x: 0, y: 0, width: 24, height: 24))
        let result = BlurRenderer.filteredRegionImage(
            region: region, mode: .solid, strength: strength,
            solidColor: NSColor.black.cgColor,
            source: whiteSource(), cropOrigin: .zero, scale: 1)
        return result!.image
    }

    func test_fullStrengthIsOpaque() {
        XCTAssertEqual(centerAlpha(solidFill(strength: 1.0)), 1.0, accuracy: 0.05)
    }

    func test_halfStrengthIsHalfOpaque() {
        XCTAssertEqual(centerAlpha(solidFill(strength: 0.5)), 0.5, accuracy: 0.06)
    }

    func test_zeroStrengthIsTransparent() {
        XCTAssertEqual(centerAlpha(solidFill(strength: 0.0)), 0.0, accuracy: 0.05)
    }

    // MARK: - Creation defaults

    func test_solidCreationDefault_isFullyOpaque() {
        let state = EditorState(sourceImage: whiteSource(), sourceURL: nil)
        state.blurMode = .solid
        // A new Solid block-out defaults to 100% opacity (a privacy cover should
        // hide completely), independent of the Gaussian strength default.
        XCTAssertEqual(blurCreationStyle(state: state).blurStrength, 1.0, accuracy: 0.0001)
    }

    func test_gaussianCreationDefault_isFullStrength() {
        let state = EditorState(sourceImage: whiteSource(), sourceURL: nil)
        state.blurMode = .gaussian
        // New blurs default to full strength across all blur types.
        XCTAssertEqual(blurCreationStyle(state: state).blurStrength, 1.0, accuracy: 0.0001)
    }
}
