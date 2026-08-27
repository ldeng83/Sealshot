import XCTest
import CoreGraphics
@testable import Sealshot

final class ShadowStyleTests: XCTestCase {
    func testPronouncedDefaults() {
        let s = ShadowStyle.pronounced
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.blur, 14)
        XCTAssertEqual(s.offset, CGSize(width: 4, height: 4))
        XCTAssertEqual(s.opacity, 0.55, accuracy: 1e-9)
        XCTAssertEqual(s.color, SerializableColor(.black))
    }

    func testOffIsDisabledButKeepsPronouncedShape() {
        XCTAssertFalse(ShadowStyle.off.enabled)
        XCTAssertEqual(ShadowStyle.off.blur, 14)
    }

    func testRoundTripsThroughCodable() throws {
        let s = ShadowStyle(enabled: true, color: SerializableColor(.systemBlue),
                            blur: 9, offset: CGSize(width: -2, height: 4), opacity: 0.3)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ShadowStyle.self, from: data)
        XCTAssertEqual(s, back)
    }
}
