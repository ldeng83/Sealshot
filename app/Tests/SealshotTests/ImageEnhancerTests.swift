import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class ImageEnhancerTests: XCTestCase {

    private func solidImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testCoreImageFallback_doublesDimensions() {
        let enhancer = ImageEnhancer()
        let src = solidImage(width: 60, height: 40)
        let out = enhancer.coreImageEnhance(src)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.width, 120)
        XCTAssertEqual(out?.height, 80)
    }

    func testEnhance_producesTwoXRegardlessOfModelAvailability() async throws {
        let enhancer = ImageEnhancer()
        let src = solidImage(width: 50, height: 30)
        let out = try await enhancer.enhance(src, params: .default)
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 60)
    }
}
