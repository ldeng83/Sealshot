import XCTest
import AppKit
@testable import Sealshot

final class SerializableColorTests: XCTestCase {

    private func assertColors(_ a: NSColor, _ b: NSColor, accuracy: Double = 0.001, file: StaticString = #filePath, line: UInt = #line) {
        let aSRGB = a.usingColorSpace(.sRGB)!
        let bSRGB = b.usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(aSRGB.redComponent),   Double(bSRGB.redComponent),   accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(aSRGB.greenComponent), Double(bSRGB.greenComponent), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(aSRGB.blueComponent),  Double(bSRGB.blueComponent),  accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(aSRGB.alphaComponent), Double(bSRGB.alphaComponent), accuracy: accuracy, file: file, line: line)
    }

    func testRoundTrip_red() {
        let s = SerializableColor(.red)
        assertColors(s.nsColor, .red)
    }

    func testRoundTrip_white() {
        let s = SerializableColor(.white)
        assertColors(s.nsColor, .white)
    }

    func testRoundTrip_systemBlue() {
        let s = SerializableColor(.systemBlue)
        assertColors(s.nsColor, .systemBlue)
    }

    func testRoundTrip_customRGBA() {
        let custom = NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 0.6)
        let s = SerializableColor(custom)
        assertColors(s.nsColor, custom)
    }

    func testRoundTrip_fullyTransparent() {
        let clear = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)
        let s = SerializableColor(clear)
        XCTAssertEqual(s.a, 0, accuracy: 0.001)
        assertColors(s.nsColor, clear)
    }
}
