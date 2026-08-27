import XCTest
@testable import Sealshot

final class SealManifestMetadataTests: XCTestCase {

    func testDecode_oldManifestWithoutMetadata_yieldsNil() throws {
        // A v2 manifest as written before this feature: no `metadata` key.
        let json = """
        {"version":2,"createdISO8601":"2026-06-08T10:00:00Z",
         "modifiedISO8601":"2026-06-08T10:00:00Z",
         "sourceSize":{"width":100,"height":50}}
        """.data(using: .utf8)!
        let m = try SealManifest.decodeJSON(from: json)
        XCTAssertNil(m.metadata)
        XCTAssertNil(m.sourceApp)
    }

    func testRoundTrip_withMetadata() throws {
        let meta = CaptureMetadata(generatedTitle: "T", userTitle: nil, tags: ["x"],
                                   category: .code, confidence: 0.7, generatorVersion: 1)
        let m = SealManifest(version: 3, createdISO8601: "c", modifiedISO8601: "mod",
                             sourceSize: .init(width: 1, height: 2),
                             sourceApp: "Safari", showingEnhanced: true, metadata: meta)
        let back = try SealManifest.decodeJSON(from: m.encodeJSON())
        XCTAssertEqual(back.metadata, meta)
        XCTAssertEqual(back.sourceApp, "Safari")
    }
}
