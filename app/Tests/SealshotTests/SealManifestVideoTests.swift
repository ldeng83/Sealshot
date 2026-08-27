import XCTest
@testable import Sealshot

final class SealManifestVideoTests: XCTestCase {
    func testLegacyV7ManifestDecodesNilVideo() throws {
        // v7 manifest (no `video` key) — must decode with video == nil.
        let json = """
        {"version":7,"createdISO8601":"t","modifiedISO8601":"t",
         "sourceSize":{"width":1920,"height":1080},"sourceApp":null}
        """.data(using: .utf8)!
        let m = try SealManifest.decodeJSON(from: json)
        XCTAssertNil(m.video)
        XCTAssertEqual(m.version, 7)
    }
    func testRoundTripsVideoInfo() throws {
        let m = SealManifest(
            version: SealManifest.currentVersion, createdISO8601: "t", modifiedISO8601: "t",
            sourceSize: .init(width: 1920, height: 1080), sourceApp: nil,
            captureKind: .screenRecording,
            video: VideoInfo(durationSeconds: 12.5, hasAudio: true))
        let back = try SealManifest.decodeJSON(from: m.encodeJSON())
        XCTAssertEqual(back.video?.durationSeconds, 12.5)
        XCTAssertEqual(back.video?.hasAudio, true)
        XCTAssertEqual(SealManifest.currentVersion, 14)
    }
}
