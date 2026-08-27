import XCTest
@testable import Sealshot

final class StyleShadowCodableTests: XCTestCase {
    func testNewFieldRoundTrips() throws {
        var s = Style(strokeColor: SerializableColor(.red), strokeWidth: 4)
        s.shadow = .pronounced
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Style.self, from: data)
        XCTAssertEqual(back.shadow, .pronounced)
    }

    func testLegacyJsonWithoutShadowDecodesToOff() throws {
        let legacy = """
        {"strokeColor":{"r":1,"g":0,"b":0,"a":1},"strokeWidth":4,"opacity":1,
         "cornerRadius":0,"fontSize":18,"isBold":false,"blurMode":"pixelate",
         "blurStrength":0.5,"startCap":"none","endCap":"filled","dashStyle":"solid"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Style.self, from: legacy)
        XCTAssertFalse(s.shadow.enabled, "legacy annotations must stay shadow-free")
    }

    func testDefaultInitIsShadowOff() {
        XCTAssertFalse(Style(strokeColor: SerializableColor(.red), strokeWidth: 4).shadow.enabled)
    }
}
