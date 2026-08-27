import XCTest
import AppKit
import CoreGraphics
@testable import Sealshot

/// Regression tests for export/copy resolution. A no-op render (scale 1.0, no
/// crop / annotations / focus) must return the source's pixels unchanged —
/// same pixel dimensions and same high-frequency detail. The blurry-export bug
/// was `render()` round-tripping the source through `NSImage(size:)` +
/// `lockFocus`, whose backing resolution depends on the current screen scale
/// rather than the source's native pixels.
@MainActor
final class RenderResolutionTests: XCTestCase {

    /// 1px-wide vertical stripes: maximum horizontal high-frequency detail.
    private func stripes(_ w: Int, _ h: Int) -> CGImage {
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        for y in 0..<h {
            for x in 0..<w {
                let v: UInt8 = (x % 2 == 0) ? 255 : 0
                let o = y * bytesPerRow + x * 4
                data[o] = v; data[o+1] = v; data[o+2] = v; data[o+3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// The exported bitmap must have the SAME pixel dimensions as the source.
    func testNoOpRender_preservesPixelDimensions() {
        let src = stripes(200, 120)
        let out = render(image: src, annotations: [], crop: nil)
        guard let rep = bitmap(out) else { XCTFail("no bitmap"); return }
        XCTAssertEqual(rep.pixelsWide, 200, "exported width \(rep.pixelsWide) != source 200")
        XCTAssertEqual(rep.pixelsHigh, 120, "exported height \(rep.pixelsHigh) != source 120")
    }

    /// The exported bitmap must keep the 1px stripes crisp. If the source was
    /// resampled, adjacent columns blur toward mid-gray and contrast collapses.
    func testNoOpRender_preservesHighFrequencyDetail() {
        let src = stripes(200, 120)
        let out = render(image: src, annotations: [], crop: nil)
        guard let rep = bitmap(out) else { XCTFail("no bitmap"); return }

        // Sample a horizontal run in the middle row; measure mean adjacent
        // contrast. Crisp 1px stripes ⇒ ~1.0; blurred ⇒ far lower.
        let y = rep.pixelsHigh / 2
        var contrastSum = 0.0
        var n = 0
        var prev: CGFloat?
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let lum = c.redComponent
            if let p = prev { contrastSum += abs(Double(lum - p)); n += 1 }
            prev = lum
        }
        let meanContrast = n > 0 ? contrastSum / Double(n) : 0
        XCTAssertGreaterThan(
            meanContrast, 0.8,
            "stripes blurred: mean adjacent contrast \(meanContrast) (crisp ≈ 1.0). Source detail was resampled away."
        )
    }

    /// Mean adjacent-pixel contrast along the middle row of a rep — crisp 1px
    /// stripes ≈ 1.0, blurred ≈ low.
    private func meanContrast(_ rep: NSBitmapImageRep) -> Double {
        let y = rep.pixelsHigh / 2
        var sum = 0.0, n = 0
        var prev: CGFloat?
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if let p = prev { sum += abs(Double(c.redComponent - p)); n += 1 }
            prev = c.redComponent
        }
        return n > 0 ? sum / Double(n) : 0
    }

    /// The focus-crop export path (`composite.cgImage(forProposedRect:)` then
    /// crop) must preserve stripe detail within the focus region.
    func testFocusRender_preservesHighFrequencyDetail() {
        let src = stripes(200, 120)
        // Focus on the middle half, in 1×-visible coords.
        let out = render(image: src, annotations: [], crop: nil,
                         focus: CGRect(x: 50, y: 30, width: 100, height: 60))
        guard let rep = bitmap(out) else { XCTFail("no bitmap"); return }
        let mc = meanContrast(rep)
        XCTAssertGreaterThan(mc, 0.8,
            "focus-crop blurred: mean adjacent contrast \(mc) (crisp ≈ 1.0), output \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    /// The scale=2 (enhanced base) path must preserve the 2× source detail.
    func testScale2Render_preservesHighFrequencyDetail() {
        let src = stripes(400, 240)   // a 2× base of a 200×120 1× space
        let out = render(image: src, annotations: [], crop: nil, scale: 2.0)
        guard let rep = bitmap(out) else { XCTFail("no bitmap"); return }
        let mc = meanContrast(rep)
        XCTAssertEqual(rep.pixelsWide, 400, "scale2 width \(rep.pixelsWide) != 400")
        XCTAssertGreaterThan(mc, 0.8,
            "scale2 blurred: mean adjacent contrast \(mc) (crisp ≈ 1.0), output \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}
