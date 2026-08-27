import XCTest
@testable import Sealshot

@MainActor
final class VideoTagBuilderTests: XCTestCase {

    func test_attributeTags_screenRecordingAndAudio() {
        XCTAssertEqual(VideoTagBuilder.attributeTags(hasAudio: true), ["screen-recording", "has-audio"])
        XCTAssertEqual(VideoTagBuilder.attributeTags(hasAudio: false), ["screen-recording"])
        XCTAssertEqual(VideoTagBuilder.attributeTags(hasAudio: nil), ["screen-recording"])
    }

    func test_contentTags_pullsCategoryAndKeywordsFromOCR() {
        let tags = VideoTagBuilder.contentTags(
            ocrText: "Stripe checkout — payment failed. 404 not found.")
        XCTAssertTrue(tags.contains("stripe"), "keyword from OCR")
        XCTAssertTrue(tags.contains("payment"), "keyword from OCR")
    }

    func test_merge_priorityUserStructuralContentFmAttributes_capsAt8() {
        // 10 inputs → first-seen order kept, capped at 8: user(a) first, attributes
        // (i,j) drop last. Single letters aren't singularized/synonym-mapped.
        let merged = VideoTagBuilder.merge(
            existing: ["a"], structural: ["b", "c", "d"],
            content: ["e", "f", "g"], fm: ["h"], attributes: ["i", "j"])
        XCTAssertEqual(merged, ["a", "b", "c", "d", "e", "f", "g", "h"])
    }

    func test_merge_preservesUserTagFirst() {
        let merged = VideoTagBuilder.merge(
            existing: ["mykeep"], structural: ["qr-code"],
            content: ["error"], fm: [], attributes: ["screen-recording"])
        XCTAssertEqual(merged.first, "mykeep")
        XCTAssertTrue(merged.contains("qr-code"))
        XCTAssertLessThanOrEqual(merged.count, 8)
    }

    // MARK: - Task 4: auto output → smartKeywords; user tags stay separate

    /// `existing` in `VideoTagBuilder.merge` is the SMART KEYWORD bucket (prior auto
    /// keywords from `metadata.smartKeywords`), not the user-tag bucket. Prior smart
    /// keywords survive in output so regeneration doesn't clobber them.
    func test_merge_existingIsSmartKeywordBucket_priorKeywordsPreserved() {
        let priorSmartKw = ["screen-recording", "stripe"]
        let merged = VideoTagBuilder.merge(
            existing: priorSmartKw, structural: ["qr-code"],
            content: ["payment"], fm: [], attributes: ["has-audio"])
        XCTAssertTrue(merged.contains("stripe"), "prior smart keyword must survive")
        XCTAssertTrue(merged.contains("screen-recording"), "prior smart keyword must survive")
        XCTAssertTrue(merged.contains("qr-code"), "new structural tag included")
        XCTAssertLessThanOrEqual(merged.count, 8)
    }

    /// Full round-trip: `VideoTagBuilder.merge` output fed into `SealMetadataStore.setVideoTags`
    /// writes to `metadata.smartKeywords`; user `metadata.tags` is never touched by automation.
    func test_videoTagBuilder_outputGoesToSmartKeywords_notUserTags() throws {
        let autoKeywords = VideoTagBuilder.merge(
            existing: [], structural: ["qr-code"],
            content: ["error"], fm: [], attributes: ["screen-recording"])
        XCTAssertFalse(autoKeywords.isEmpty, "auto-generated keyword list must be non-empty")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vtb-task4-\(UUID().uuidString).seal")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "2026-01-01T00:00:00Z",
            modifiedISO8601: "2026-01-01T00:00:00Z",
            sourceSize: SealManifest.Size(width: 100, height: 100),
            sourceApp: nil,
            metadata: CaptureMetadata(generatedTitle: "rec", userTitle: nil,
                                      tags: ["important"], smartKeywords: [],
                                      category: .other, confidence: 0, generatorVersion: 1),
            video: VideoInfo(durationSeconds: 5, hasAudio: false))
        try manifest.encodeJSON().write(to: url.appendingPathComponent("manifest.json"))

        try SealMetadataStore.setVideoTags(autoKeywords, version: VideoTagBuilder.version, to: url)

        let stored = try SealMetadataStore.readManifest(at: url).metadata!
        XCTAssertFalse(stored.smartKeywords.isEmpty, "auto tags must land in smartKeywords")
        XCTAssertEqual(stored.tags, ["important"], "user tags must be untouched by auto-tagging")
    }
}
