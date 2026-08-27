import XCTest
@testable import Sealshot

final class VideoSummaryStoreTests: XCTestCase {

    func test_videoInfoRoundTripsSummary() throws {
        let v = SealManifest.VideoInfo(durationSeconds: 12, hasAudio: true,
                                       summary: "A demo.\n- step one", summaryVersion: 1)
        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(SealManifest.VideoInfo.self, from: data)
        XCTAssertEqual(back.summary, "A demo.\n- step one")
        XCTAssertEqual(back.summaryVersion, 1)
        XCTAssertEqual(back.durationSeconds, 12)
        XCTAssertEqual(back.hasAudio, true)
    }

    func test_videoInfoDecodesOldManifestWithoutSummary() throws {
        let json = #"{"durationSeconds":12,"hasAudio":true}"#.data(using: .utf8)!
        let v = try JSONDecoder().decode(SealManifest.VideoInfo.self, from: json)
        XCTAssertNil(v.summary)
        XCTAssertEqual(v.summaryVersion, 0)
    }

    func test_memberwiseInitDefaults() {
        let v = SealManifest.VideoInfo(durationSeconds: 1, hasAudio: nil)
        XCTAssertNil(v.summary)
        XCTAssertEqual(v.summaryVersion, 0)
        XCTAssertEqual(v.tagVersion, 0)
    }

    func test_videoInfoRoundTripsTagVersion() throws {
        let v = SealManifest.VideoInfo(durationSeconds: 5, hasAudio: false,
                                       summary: nil, summaryVersion: 0, tagVersion: 1)
        let back = try JSONDecoder().decode(SealManifest.VideoInfo.self,
                                            from: JSONEncoder().encode(v))
        XCTAssertEqual(back.tagVersion, 1)
    }

    func test_videoInfoDecodesOldManifestWithoutTagVersion() throws {
        let json = #"{"durationSeconds":12,"hasAudio":true,"summaryVersion":1}"#.data(using: .utf8)!
        let v = try JSONDecoder().decode(SealManifest.VideoInfo.self, from: json)
        XCTAssertEqual(v.tagVersion, 0)
    }

    @MainActor
    func test_setVideoTags_writesSmartKeywordsToMetadataAndStampsVersion() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = FileManager.default.temporaryDirectory
            .appendingPathComponent("payload-\(UUID().uuidString).mov")
        try Data("fake".utf8).write(to: payload)
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "2026-06-28T10:00:00Z", modifiedISO8601: "2026-06-28T10:00:00Z",
            sourceSize: SealManifest.Size(width: 1920, height: 1080), sourceApp: nil,
            captureKind: .screenRecording,
            video: SealManifest.VideoInfo(durationSeconds: 10, hasAudio: true))
        try VideoSealPackageIO.write(
            to: dir, payloadTempURL: payload, originalUTI: "com.apple.quicktime-movie",
            manifest: manifest, thumbnailPNG: nil,
            crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        try SealMetadataStore.setVideoTags(["dashboard", "stripe"], version: 1, to: dir)

        let back = try SealMetadataStore.readManifest(at: dir)
        XCTAssertEqual(back.metadata?.smartKeywords, ["dashboard", "stripe"])
        XCTAssertEqual(back.metadata?.tags, [])            // user tags untouched
        XCTAssertEqual(back.video?.tagVersion, 1)
        XCTAssertEqual(back.video?.durationSeconds, 10)   // other video fields preserved
    }
}
