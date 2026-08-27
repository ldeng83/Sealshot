import XCTest
@testable import Sealshot

@MainActor
final class VideoMetadataGateTests: XCTestCase {

    private func video(summary: String?, sVer: Int, tVer: Int) -> SealManifest.VideoInfo {
        SealManifest.VideoInfo(durationSeconds: 10, hasAudio: true,
                               summary: summary, summaryVersion: sVer, tagVersion: tVer)
    }

    func test_freshVideo_needsBothWhenAiOn() {
        let g = VideoMetadataCoordinator.needs(video: video(summary: nil, sVer: 0, tVer: 0),
                                               aiOn: true, aiEnabled: true)
        XCTAssertTrue(g.summary)
        XCTAssertTrue(g.tags)
    }

    func test_aiPrefOff_needsNothing() {
        // The "Use on-device AI" toggle gates ALL auto-metadata, tags included
        // (images already behave this way; videos must match).
        let g = VideoMetadataCoordinator.needs(video: video(summary: nil, sVer: 0, tVer: 0),
                                               aiOn: false, aiEnabled: false)
        XCTAssertFalse(g.summary)
        XCTAssertFalse(g.tags)
    }

    func test_aiPrefOnWithoutFM_needsTagsOnly() {
        // Tags are deterministic — they generate without FM; summary needs FM.
        let g = VideoMetadataCoordinator.needs(video: video(summary: nil, sVer: 0, tVer: 0),
                                               aiOn: false, aiEnabled: true)
        XCTAssertFalse(g.summary)
        XCTAssertTrue(g.tags)
    }

    func test_upToDate_needsNothing() {
        let g = VideoMetadataCoordinator.needs(
            video: video(summary: "done", sVer: VideoSummarizer.summaryVersion,
                         tVer: VideoTagBuilder.version),
            aiOn: true, aiEnabled: true)
        XCTAssertFalse(g.summary)
        XCTAssertFalse(g.tags)
    }

    func test_emptyTerminalSummaryCountsAsDone() {
        // "" is the terminal marker — summary is done, don't regenerate.
        let g = VideoMetadataCoordinator.needs(
            video: video(summary: "", sVer: VideoSummarizer.summaryVersion,
                         tVer: VideoTagBuilder.version),
            aiOn: true, aiEnabled: true)
        XCTAssertFalse(g.summary)
        XCTAssertFalse(g.tags)
    }

    func test_tagsStale_needsTagsOnly() {
        let g = VideoMetadataCoordinator.needs(
            video: video(summary: "done", sVer: VideoSummarizer.summaryVersion, tVer: 0),
            aiOn: true, aiEnabled: true)
        XCTAssertFalse(g.summary)
        XCTAssertTrue(g.tags)
    }

    func test_userSummaryOverride_suppressesSummaryGeneration() {
        let g = VideoMetadataCoordinator.needs(
            video: video(summary: nil, sVer: 0, tVer: 0),
            aiOn: true, aiEnabled: true, userSummaryPresent: true)
        XCTAssertFalse(g.summary, "a manual override makes generation pointless")
        XCTAssertTrue(g.tags)
    }
}
