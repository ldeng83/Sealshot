import XCTest
import CoreGraphics
@testable import Sealshot

final class AnnotationCodecFocusTests: XCTestCase {
    func testRoundTripsFocus() throws {
        let focus = CGRect(x: 5, y: 6, width: 20, height: 10)
        let data = try encodeAnnotations([], crop: nil, focus: focus)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.focus, focus)
        XCTAssertNil(decoded.crop)
    }

    func testOldV3WithoutFocusDecodesNil() throws {
        let json = #"{"version":3,"annotations":[],"croppedRect":null}"#.data(using: .utf8)!
        let decoded = try decodeAnnotations(from: json)
        XCTAssertNil(decoded.focus)
    }
}
