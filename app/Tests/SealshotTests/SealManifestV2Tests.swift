import XCTest
@testable import Sealshot

final class SealManifestV2Tests: XCTestCase {

    func testV2RoundTrip_carriesNewFields() throws {
        let m = SealManifest(
            version: 2, createdISO8601: "2026-06-02T00:00:00Z",
            modifiedISO8601: "2026-06-02T00:00:00Z",
            sourceSize: .init(width: 100, height: 80), sourceApp: nil,
            showingEnhanced: true
        )
        let decoded = try SealManifest.decodeJSON(from: m.encodeJSON())
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.showingEnhanced, true)
    }

    func testV1JSON_decodesWithNilNewFields() throws {
        let v1 = """
        {"version":1,"createdISO8601":"x","modifiedISO8601":"x",\
        "sourceSize":{"width":10,"height":10}}
        """.data(using: .utf8)!
        let decoded = try SealManifest.decodeJSON(from: v1)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertNil(decoded.showingEnhanced)
    }
}
