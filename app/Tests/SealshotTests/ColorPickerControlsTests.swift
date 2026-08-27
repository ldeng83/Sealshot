import XCTest
import AppKit
@testable import Sealshot

final class ColorPickerControlsTests: XCTestCase {

    func test_hsb_fromPrimaryColors() {
        let red = HSB(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(red.hue, 0, accuracy: 0.01)
        XCTAssertEqual(red.saturation, 1, accuracy: 0.01)
        XCTAssertEqual(red.brightness, 1, accuracy: 0.01)
    }

    func test_hsb_nsColorRoundTrip() {
        let original = NSColor(srgbRed: 0.2, green: 0.55, blue: 0.8, alpha: 1)
        let back = HSB(original).nsColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(back.redComponent,   0.2,  accuracy: 0.01)
        XCTAssertEqual(back.greenComponent, 0.55, accuracy: 0.01)
        XCTAssertEqual(back.blueComponent,  0.8,  accuracy: 0.01)
    }

    func test_hsb_nsColorIsOpaque() {
        let c = HSB(hue: 0.5, saturation: 0.5, brightness: 0.5).nsColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(c.alphaComponent, 1, accuracy: 0.001)
    }
}
