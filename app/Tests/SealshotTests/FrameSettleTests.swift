import XCTest
import CoreGraphics
@testable import Sealshot

final class FrameSettleTests: XCTestCase {

    /// A 200×200 grayscale image whose pixel at (x,y) is `value(x,y)`.
    private func image(_ value: (Int, Int) -> UInt8) -> CGImage {
        let n = 200
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * n)
        for y in 0..<n { for x in 0..<n { p[y * ctx.bytesPerRow + x] = value(x, y) } }
        return ctx.makeImage()!
    }

    func testIdenticalFramesAreStable() {
        let a = image { x, _ in UInt8((x * 7) & 0xFF) }
        XCTAssertTrue(FrameSettle.isStable(a, a))
    }

    func testSubThresholdNoiseIsStable() {
        let a = image { x, y in UInt8(((x + y) * 3) & 0xFF) }
        let b = image { x, y in UInt8((((x + y) * 3) + 1) & 0xFF) }   // +1 everywhere
        XCTAssertTrue(FrameSettle.isStable(a, b), "uniform +1 is below the threshold")
    }

    func testShiftedContentIsNotStable() {
        // Sharp horizontal band that moves a lot between frames (mid-scroll).
        let a = image { _, y in (40..<60).contains(y) ? 0 : 255 }
        let b = image { _, y in (140..<160).contains(y) ? 0 : 255 }
        XCTAssertFalse(FrameSettle.isStable(a, b), "content jumped — not settled")
    }
}
