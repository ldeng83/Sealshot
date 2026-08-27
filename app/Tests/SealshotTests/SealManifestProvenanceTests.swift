import XCTest
@testable import Sealshot

final class SealManifestProvenanceTests: XCTestCase {
    func testLegacyV5ManifestDecodesWithNilProvenance() throws {
        // A v5 manifest written before provenance existed: keys absent.
        let json = """
        {"version":5,"createdISO8601":"2026-01-01T00:00:00Z",
         "modifiedISO8601":"2026-01-01T00:00:00Z",
         "sourceSize":{"width":10,"height":10},"sourceApp":null}
        """.data(using: .utf8)!
        let m = try SealManifest.decodeJSON(from: json)
        XCTAssertNil(m.captureKind)
        XCTAssertNil(m.captureMode)
        XCTAssertNil(m.pageDomain)
        XCTAssertEqual(m.version, 5)
    }
    func testRoundTripsProvenance() throws {
        let m = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "t", modifiedISO8601: "t",
            sourceSize: .init(width: 4, height: 4), sourceApp: "Safari",
            captureKind: .screenshot, captureMode: .window, pageDomain: "github.com")
        let back = try SealManifest.decodeJSON(from: m.encodeJSON())
        XCTAssertEqual(back.captureKind, .screenshot)
        XCTAssertEqual(back.captureMode, .window)
        XCTAssertEqual(back.pageDomain, "github.com")
        XCTAssertEqual(SealManifest.currentVersion, 14)
    }
}
