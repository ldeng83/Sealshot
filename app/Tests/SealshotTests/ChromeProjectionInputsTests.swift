import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class ChromeProjectionInputsTests: XCTestCase {

    private func makeImage(_ w: Int = 120, _ h: Int = 90) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    func test_marqueeRect_defaultsNil_andStores() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        XCTAssertNil(state.marqueeRect)
        state.marqueeRect = CGRect(x: 1, y: 2, width: 3, height: 4)
        XCTAssertEqual(state.marqueeRect, CGRect(x: 1, y: 2, width: 3, height: 4))
    }
}
