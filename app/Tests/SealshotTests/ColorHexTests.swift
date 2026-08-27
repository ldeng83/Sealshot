import XCTest
import AppKit
@testable import Sealshot

final class ColorHexTests: XCTestCase {

    func test_hexString_formatsUppercaseRRGGBB() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(hexString(from: red), "#FF0000")
        let teal = NSColor(srgbRed: 0.0, green: 0.5, blue: 0.5, alpha: 1)
        XCTAssertEqual(hexString(from: teal), "#008080")
    }

    func test_hexString_ignoresAlpha() {
        let translucent = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.25)
        XCTAssertEqual(hexString(from: translucent), "#0000FF")
    }

    func test_colorFromHex_parsesSixDigits() {
        let c = color(fromHex: "#00FF80")!.usingColorSpace(.sRGB)!
        XCTAssertEqual(c.redComponent, 0, accuracy: 0.004)
        XCTAssertEqual(c.greenComponent, 1, accuracy: 0.004)
        XCTAssertEqual(c.blueComponent, 0.5, accuracy: 0.004)
        XCTAssertEqual(c.alphaComponent, 1, accuracy: 0.004)
    }

    func test_colorFromHex_acceptsNoHashAndThreeDigits() {
        XCTAssertNotNil(color(fromHex: "FF0000"))
        let short = color(fromHex: "#0F0")!.usingColorSpace(.sRGB)!
        XCTAssertEqual(short.greenComponent, 1, accuracy: 0.004)
        XCTAssertEqual(short.redComponent, 0, accuracy: 0.004)
    }

    func test_colorFromHex_roundTrips() {
        let original = "#3A7BD5"
        XCTAssertEqual(hexString(from: color(fromHex: original)!), original)
    }

    func test_colorFromHex_invalidReturnsNil() {
        XCTAssertNil(color(fromHex: ""))
        XCTAssertNil(color(fromHex: "#12"))
        XCTAssertNil(color(fromHex: "#GGGGGG"))
        XCTAssertNil(color(fromHex: "#1234567"))
    }
}
