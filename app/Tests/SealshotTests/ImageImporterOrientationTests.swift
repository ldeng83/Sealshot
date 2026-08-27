import XCTest
import CoreGraphics
import ImageIO
@testable import Sealshot

/// Imported images must be orientation-normalized (baked upright). A rotated
/// photo (e.g. a portrait phone shot stored landscape with an EXIF flag) would
/// otherwise feed sideways pixels to display, OCR, tagging and redaction — and a
/// sideways glyph misreads (a rotated "6" as "8").
final class ImageImporterOrientationTests: XCTestCase {

    private func solid(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    func testRightOrientationSwapsToPortrait() {
        // .right (EXIF 6) is the classic portrait phone shot stored landscape:
        // a 40×20 buffer becomes an upright 20×40 image.
        let upright = ImageImporter.orientedUpright(solid(40, 20), .right)
        XCTAssertEqual(upright.width, 20)
        XCTAssertEqual(upright.height, 40)
    }

    func testLeftOrientationSwapsToPortrait() {
        let upright = ImageImporter.orientedUpright(solid(40, 20), .left)
        XCTAssertEqual(upright.width, 20)
        XCTAssertEqual(upright.height, 40)
    }

    func testUpOrientationIsUnchanged() {
        let same = ImageImporter.orientedUpright(solid(40, 20), .up)
        XCTAssertEqual(same.width, 40)
        XCTAssertEqual(same.height, 20)
    }

    func testDownOrientationKeepsDimensions() {
        // 180° rotation — dimensions unchanged, but it must still produce a valid image.
        let flipped = ImageImporter.orientedUpright(solid(40, 20), .down)
        XCTAssertEqual(flipped.width, 40)
        XCTAssertEqual(flipped.height, 20)
    }
}
