import XCTest
@testable import Sealshot

@MainActor
final class SealManifestTests: XCTestCase {

    func test_codableRoundTrip() throws {
        let m = SealManifest(
            version: 1,
            createdISO8601: "2026-05-28T10:00:00Z",
            modifiedISO8601: "2026-05-28T10:05:00Z",
            sourceSize: SealManifest.Size(width: 1920, height: 1080),
            sourceApp: "Safari"
        )
        let data = try m.encodeJSON()
        let decoded = try SealManifest.decodeJSON(from: data)
        XCTAssertEqual(decoded, m)
    }

    func test_sourceAppIsOptional() throws {
        let m = SealManifest(
            version: 1,
            createdISO8601: "2026-05-28T10:00:00Z",
            modifiedISO8601: "2026-05-28T10:00:00Z",
            sourceSize: SealManifest.Size(width: 800, height: 600),
            sourceApp: nil
        )
        let data = try m.encodeJSON()
        let decoded = try SealManifest.decodeJSON(from: data)
        XCTAssertNil(decoded.sourceApp)
    }
}
