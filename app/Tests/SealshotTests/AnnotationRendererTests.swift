import XCTest
import AppKit
@testable import Sealshot

final class AnnotationRendererTests: XCTestCase {

    // MARK: - cropAndClipAnnotations

    func testCropAndClip_translatesArrowByCropOrigin() {
        let arrow = Annotation(
            geometry: .arrow(start: CGPoint(x: 20, y: 20), end: CGPoint(x: 40, y: 40)),
            style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        )
        let crop = CGRect(x: 10, y: 10, width: 50, height: 50)
        let result = cropAndClipAnnotations([arrow], to: crop)
        XCTAssertEqual(result.count, 1)
        if case let .arrow(start, end) = result[0].geometry {
            XCTAssertEqual(start, CGPoint(x: 10, y: 10))
            XCTAssertEqual(end,   CGPoint(x: 30, y: 30))
        } else {
            XCTFail("expected arrow")
        }
        XCTAssertEqual(result[0].id, arrow.id, "id preserved across crop")
    }

    func testCropAndClip_rectangleIntersectsCrop() {
        let rect = Annotation(
            geometry: .rectangle(rect: CGRect(x: 5, y: 5, width: 100, height: 100)),
            style: Style(strokeColor: SerializableColor(.blue), strokeWidth: 3)
        )
        let crop = CGRect(x: 10, y: 10, width: 50, height: 50)
        let result = cropAndClipAnnotations([rect], to: crop)
        XCTAssertEqual(result.count, 1)
        if case let .rectangle(r) = result[0].geometry {
            XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 50, height: 50))
        } else {
            XCTFail("expected rectangle")
        }
    }

    func testCropAndClip_droppedWhenOutsideCrop() {
        let rect = Annotation(
            geometry: .rectangle(rect: CGRect(x: 200, y: 200, width: 10, height: 10)),
            style: Style(strokeColor: SerializableColor(.blue), strokeWidth: 3)
        )
        let crop = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = cropAndClipAnnotations([rect], to: crop)
        XCTAssertEqual(result.count, 0)
    }

    func testRender_emptyAnnotations_returnsImageSizedFromSource() {
        let source = makeCGImage(width: 80, height: 60)
        let composite = render(image: source, annotations: [], crop: nil)
        XCTAssertEqual(composite.size, CGSize(width: 80, height: 60))
    }

    func testRender_withCrop_returnsImageSizedFromCropRect() {
        let source = makeCGImage(width: 200, height: 200)
        let crop = CGRect(x: 50, y: 50, width: 100, height: 100)
        let composite = render(image: source, annotations: [], crop: crop)
        XCTAssertEqual(composite.size, CGSize(width: 100, height: 100))
    }

    // MARK: - v9 background fill

    func testRender_backgroundFill_showsThroughTransparentBase() {
        // A fully transparent base + a red backgroundFill → the composite is red.
        let base = makeCGImage(width: 20, height: 20)  // all-transparent
        let composite = render(image: base, annotations: [], crop: nil,
                               backgroundFill: SerializableColor(r: 1, g: 0, b: 0, a: 1))
        let rep = NSBitmapImageRep(data: composite.tiffRepresentation!)!
        let c = rep.colorAt(x: 10, y: 10)!.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(c.redComponent, 0.9)
        XCTAssertLessThan(c.blueComponent, 0.1)
        XCTAssertGreaterThan(c.alphaComponent, 0.9)
    }

    func testRender_nilBackgroundFill_leavesTransparentBaseTransparent() {
        // No fill → a transparent base stays transparent in the export.
        let base = makeCGImage(width: 20, height: 20)
        let composite = render(image: base, annotations: [], crop: nil, backgroundFill: nil)
        let rep = NSBitmapImageRep(data: composite.tiffRepresentation!)!
        XCTAssertLessThan(rep.colorAt(x: 10, y: 10)!.usingColorSpace(.sRGB)!.alphaComponent, 0.1)
    }

    func testRender_backgroundFill_hiddenBehindOpaqueBase() {
        // An opaque (red) base fully covers the fill — the fill is invisible.
        let base = solidRed(20, 20)
        let composite = render(image: base, annotations: [], crop: nil,
                               backgroundFill: SerializableColor(r: 0, g: 0, b: 1, a: 1))
        let rep = NSBitmapImageRep(data: composite.tiffRepresentation!)!
        let c = rep.colorAt(x: 10, y: 10)!.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(c.redComponent, 0.9, "opaque base wins over the fill")
        XCTAssertLessThan(c.blueComponent, 0.1)
    }

    // MARK: - helpers

    private func solidRed(_ w: Int, _ h: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Red background: blueComponent ≈ 0, so a blue stroke is detectable and
        // an unstroked pixel has blueComponent < 0.3.
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    func test_rectangle_strokeWidthZero_skipsBorder() {
        let src = solidRed(40, 40)
        func bluePixelAtEdge(strokeWidth: CGFloat) -> CGFloat {
            let a = Annotation(
                geometry: .rectangle(rect: CGRect(x: 12, y: 12, width: 16, height: 16)),
                style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 1, a: 1),
                             strokeWidth: strokeWidth, fillColor: nil))
            let img = render(image: src, annotations: [a], crop: nil)
            let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
            return rep.colorAt(x: 12, y: 20)?.usingColorSpace(.sRGB)?.blueComponent ?? 0
        }
        XCTAssertGreaterThan(bluePixelAtEdge(strokeWidth: 8), 0.5)   // thick border IS drawn
        XCTAssertLessThan(bluePixelAtEdge(strokeWidth: 0), 0.3)      // zero-width border is skipped
    }

    private func makeCGImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }
}
