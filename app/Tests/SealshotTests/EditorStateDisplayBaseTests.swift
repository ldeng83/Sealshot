import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class EditorStateDisplayBaseTests: XCTestCase {

    private func img(_ w: Int, _ h: Int) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return c.makeImage()!
    }

    func testDisplayScale_originalIsOne() {
        let s = EditorState(sourceImage: img(100, 80), sourceURL: nil)
        XCTAssertEqual(s.displayScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(s.displayBase.width, 100)
    }

    func testDisplayScale_enhancedShownIsTwo() {
        let s = EditorState(sourceImage: img(100, 80), sourceURL: nil,
                            enhancedImage: img(200, 160), showingEnhanced: true)
        XCTAssertEqual(s.displayScale, 2.0, accuracy: 0.0001)
        XCTAssertEqual(s.displayBase.width, 200)
    }

    func testDisplayBase_enhancedHiddenUsesSource() {
        let s = EditorState(sourceImage: img(100, 80), sourceURL: nil,
                            enhancedImage: img(200, 160), showingEnhanced: false)
        XCTAssertEqual(s.displayBase.width, 100)
        XCTAssertEqual(s.displayScale, 1.0, accuracy: 0.0001)
    }
}
