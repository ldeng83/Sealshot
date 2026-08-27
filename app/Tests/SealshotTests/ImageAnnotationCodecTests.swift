import XCTest
@testable import Sealshot

final class ImageAnnotationCodecTests: XCTestCase {

    func testImageGeometry_roundTripsThroughEnvelope() throws {
        let original = Annotation(
            geometry: .image(rect: CGRect(x: 10, y: 20, width: 300, height: 200),
                             assetID: "ABC-123"),
            style: Style(strokeColor: SerializableColor(.black), strokeWidth: 0,
                         opacity: 0.8))
        let data = try encodeAnnotations([original], crop: nil, focus: nil)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.annotations, [original])
    }

    func testEnvelope_writesVersion12() throws {
        let data = try encodeAnnotations([], crop: nil, focus: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["version"] as? Int, 12)   // v11 contentClip, v12 textLayoutWidth
    }

    /// A v4 envelope (pre-image era) must keep decoding unchanged.
    /// Fixture frozen from the real v4 encoder output (sortedKeys) before the
    /// version bump. CGRect encodes as [[x,y],[w,h]] via synthesized Codable.
    func testEnvelopeV4_stillDecodes() throws {
        let v4 = """
        {"annotations":[{"geometry":{"rectangle":{"rect":[[10,20],[100,80]]}},"id":"00000000-0000-0000-0000-000000000042","style":{"blurMode":"pixelate","blurStrength":0.5,"cornerRadius":0,"fontSize":18,"isBold":false,"opacity":1,"strokeColor":{"a":1,"b":0,"g":0,"r":1},"strokeWidth":3}}],"version":4}
        """.data(using: .utf8)!
        let decoded = try decodeAnnotations(from: v4)
        XCTAssertEqual(decoded.annotations.count, 1)
    }

    func testManifest_currentVersionIs14() {
        XCTAssertEqual(SealManifest.currentVersion, 14)
    }
}
