import XCTest
import CoreGraphics
import AppKit
@testable import Sealshot

final class TATRDetectorSmokeTests: XCTestCase {

    // The bundled model must load.
    func test_detector_modelLoads_andDetectReturnsWithoutCrashing() {
        let detector = TATRDetector()
        // A blank image should run cleanly and (almost certainly) find no tables.
        let blank = Self.solidImage(width: 400, height: 400)
        _ = detector.detect(blank)   // must not crash
    }

    // On a real table screenshot, detection finds at least one box.
    func test_detector_findsTableInFixture() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "table-sample", withExtension: "png"),
              let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw XCTSkip("fixture table-sample.png not present") }
        let boxes = TATRDetector().detect(img)
        XCTAssertGreaterThanOrEqual(boxes.count, 1, "expected at least one detected table")
        for b in boxes {   // all boxes are valid source-normalized rects
            XCTAssertTrue((0...1).contains(b.minX) && (0...1).contains(b.maxX))
            XCTAssertTrue((0...1).contains(b.minY) && (0...1).contains(b.maxY))
        }
    }

    private static func solidImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}
