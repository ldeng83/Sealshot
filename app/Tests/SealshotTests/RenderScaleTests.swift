import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class RenderScaleTests: XCTestCase {

    private func img(_ w: Int, _ h: Int) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()!
    }

    func testScale1_outputMatchesSource() {
        let out = render(image: img(100, 80), annotations: [], crop: nil)
        XCTAssertEqual(out.size.width, 100, accuracy: 0.5)
        XCTAssertEqual(out.size.height, 80, accuracy: 0.5)
    }

    func testScale2_outputDoubled() {
        // base is the 2× bitmap; scale 2 → output is 2× the 1× annotation space
        let out = render(image: img(200, 160), annotations: [], crop: nil, scale: 2.0)
        XCTAssertEqual(out.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(out.size.height, 160, accuracy: 0.5)
    }

    func testScale2_annotationLandsAtScaledPosition() {
        // 1× annotation space: 100×80. A filled red rect at 1× (10,10,30,30).
        // base is the 2× bitmap (200×160). Output NSImage size is 200×160.
        //
        // flipRectY maps image-space (10,10,30,30) → NSImage-space (10,40,30,30)
        // (y = 80-10-30 = 40 in 1× NSImage coords, which is bottom-left quadrant).
        // After scale:2 transform the rect occupies device pixels (20,80,60,60)
        // from the NSImage bottom-left origin.
        //
        // NSBitmapImageRep.colorAt uses top-left origin, so the rectangle in
        // bitmap coords (for a 200×160 pixel bitmap) is:
        //   x: 20..80,  y: 160-80-60 = 20 → 20..80  (top-left quadrant).
        //
        // Fractional coords in [0,1] so the probe is backing-scale–agnostic:
        //   inside fraction  ≈ (0.25, 0.25)  → near rect centre (50,50) in 200×160
        //   outside fraction ≈ (0.90, 0.88)  → bottom-right corner (180,140) in 200×160
        let base = img(200, 160)   // gray (0.5,0.5,0.5)
        let red = SerializableColor(r: 1, g: 0, b: 0, a: 1)
        let rectAnn = Annotation(
            id: UUID(),
            geometry: .rectangle(rect: CGRect(x: 10, y: 10, width: 30, height: 30)),
            style: Style(strokeColor: red, strokeWidth: 0, opacity: 1.0, fillColor: red)
        )
        let out = render(image: base, annotations: [rectAnn], crop: nil, scale: 2.0)

        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            XCTFail("no bitmap rep"); return
        }

        let pw = rep.pixelsWide
        let ph = rep.pixelsHigh

        // Scan every pixel for the reddest one; accumulate a centroid.
        var sumX: Double = 0; var sumY: Double = 0; var redCount: Int = 0
        for py in 0..<ph {
            for px in 0..<pw {
                guard let c = rep.colorAt(x: px, y: py),
                      let srgb = c.usingColorSpace(.sRGB) else { continue }
                if srgb.redComponent > 0.6 && srgb.greenComponent < 0.4 {
                    sumX += Double(px); sumY += Double(py); redCount += 1
                }
            }
        }

        XCTAssertGreaterThan(redCount, 0, "No red pixels found — annotation may not have rendered at all")
        guard redCount > 0 else { return }

        // Normalised centroid of red pixels (0..1 each axis).
        let cx = sumX / Double(redCount) / Double(pw)
        let cy = sumY / Double(redCount) / Double(ph)

        // The 1× rect (10,10,30,30) in a 100×80 space maps to the rect
        // (10..40, 10..40) from the NSImage bottom-left, which after flip
        // becomes y = 80-40 = 40..70 from the top in 1× terms, and scaled
        // to device pixels occupies x: 20..80, y: 20..80 in a 200×160 bitmap.
        // Normalised that is x ∈ [0.10, 0.40], y ∈ [0.10, 0.40] (top-left quadrant).
        //
        // Allow a generous ±0.15 margin to absorb subpixel aliasing and any
        // minor backing-scale rounding.
        XCTAssertLessThan(cx,    0.55, "Red centroid x=\(cx) is too far right — rect may be mis-scaled")
        XCTAssertGreaterThan(cx, 0.05, "Red centroid x=\(cx) is too far left")
        XCTAssertLessThan(cy,    0.55, "Red centroid y=\(cy) is too far down (bitmap top-left origin)")
        XCTAssertGreaterThan(cy, 0.05, "Red centroid y=\(cy) is too far up")
    }
}
