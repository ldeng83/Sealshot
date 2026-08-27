import XCTest
import CoreGraphics
@testable import Sealshot

final class CutAnnotationCodecTests: XCTestCase {
    func test_cutGeometry_roundTripsThroughCodec() throws {
        let ann = Annotation(id: UUID(),
                             geometry: .cut(rect: CGRect(x: 10, y: 20, width: 30, height: 40)),
                             style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1),
                                         strokeWidth: 0))
        let data = try encodeAnnotations([ann], crop: nil)
        let decoded = try decodeAnnotations(from: data).annotations
        XCTAssertEqual(decoded.count, 1)
        guard case let .cut(rect) = decoded[0].geometry else {
            return XCTFail("expected .cut, got \(decoded[0].geometry)")
        }
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertTrue(decoded[0].geometry.isCut)
    }

    func test_encodeWritesVersion12() throws {
        let data = try encodeAnnotations([], crop: nil)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["version"] as? Int, 12)   // v11 contentClip, v12 textLayoutWidth
    }
}

/// v8: the document-resize target rides the envelope; absent key (all pre-v8
/// files) decodes to nil.
final class ResizedSizeCodecTests: XCTestCase {
    func test_resizedSize_roundTrips() throws {
        let data = try encodeAnnotations([], crop: CGRect(x: 0, y: 0, width: 100, height: 50),
                                         resizedSize: CGSize(width: 1280, height: 720))
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.resizedSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(decoded.crop, CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    func test_missingKey_decodesNil_v7Compatibility() throws {
        let v7 = #"{"version":7,"annotations":[],"croppedRect":null,"focusRect":null}"#
        let decoded = try decodeAnnotations(from: Data(v7.utf8))
        XCTAssertNil(decoded.resizedSize)
    }
}

/// v8 also carries the background-removal display flag.
final class ShowingCutoutCodecTests: XCTestCase {
    func test_showingCutout_roundTrips() throws {
        let data = try encodeAnnotations([], crop: nil, showingCutout: true)
        XCTAssertTrue(try decodeAnnotations(from: data).showingCutout)
        let off = try encodeAnnotations([], crop: nil)
        XCTAssertFalse(try decodeAnnotations(from: off).showingCutout)
    }

    func test_missingKey_decodesFalse() throws {
        let v8 = #"{"version":8,"annotations":[],"croppedRect":null,"focusRect":null}"#
        XCTAssertFalse(try decodeAnnotations(from: Data(v8.utf8)).showingCutout)
    }
}
