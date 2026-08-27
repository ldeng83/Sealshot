import XCTest
@testable import Sealshot

final class VideoSummaryTests: XCTestCase {

    func testFrameCount_scalesSubLinearly() {
        // count = round(1.3·√seconds). ~1min matches the old ~6s density (10).
        XCTAssertEqual(VideoSummary.frameCount(durationSeconds: 60), 10)
        XCTAssertEqual(VideoSummary.frameCount(durationSeconds: 15), 5)
        XCTAssertEqual(VideoSummary.frameCount(durationSeconds: 300), 23)
    }

    func testFrameCount_clampsToFloorAndCeiling() {
        XCTAssertEqual(VideoSummary.frameCount(durationSeconds: 2), 4)      // floor
        XCTAssertEqual(VideoSummary.frameCount(durationSeconds: 600), 24)   // ceiling
        XCTAssertEqual(VideoSummary.frameCount(durationSeconds: 3600), 24)
    }

    func testFrameCount_zeroForNonPositiveDuration() {
        XCTAssertEqual(VideoSummary.frameCount(durationSeconds: 0), 0)
        XCTAssertEqual(VideoSummary.frameCount(durationSeconds: -5), 0)
    }

    func testSampleTimes_evenMidpointsAtAdaptiveCount() {
        // 2s → floored to 4 frames → segment midpoints.
        XCTAssertEqual(VideoSummary.sampleTimes(durationSeconds: 2), [0.25, 0.75, 1.25, 1.75])
    }

    func testSampleTimes_spreadAcrossWholeDurationForLongVideo() {
        let t = VideoSummary.sampleTimes(durationSeconds: 600)
        XCTAssertEqual(t.count, 24)                        // ceiling
        XCTAssertTrue(t.allSatisfy { $0 > 0 && $0 < 600 })
        XCTAssertGreaterThan(t.last!, 575, "samples should reach the end")
    }

    func testSampleTimes_zeroOrNegativeDuration_empty() {
        XCTAssertTrue(VideoSummary.sampleTimes(durationSeconds: 0).isEmpty)
        XCTAssertTrue(VideoSummary.sampleTimes(durationSeconds: -5).isEmpty)
    }

    func testDedupe_dropsConsecutiveRepeatsAndEmpties() {
        let f = [
            VideoSummary.FrameText(timeSeconds: 0, text: "Login screen"),
            VideoSummary.FrameText(timeSeconds: 3, text: "Login   screen"),   // whitespace-equal
            VideoSummary.FrameText(timeSeconds: 6, text: "   "),              // empty
            VideoSummary.FrameText(timeSeconds: 9, text: "Dashboard"),
            VideoSummary.FrameText(timeSeconds: 12, text: "Login screen"),    // repeat, but not adjacent
        ]
        let out = VideoSummary.dedupe(f)
        XCTAssertEqual(out.map(\.text), ["Login screen", "Dashboard", "Login screen"])
        XCTAssertEqual(out.map(\.timeSeconds), [0, 9, 12])
    }

    func testAggregate_formatsTimestamps() {
        let f = [VideoSummary.FrameText(timeSeconds: 1, text: "hello"),
                 VideoSummary.FrameText(timeSeconds: 65, text: "world")]
        XCTAssertEqual(VideoSummary.aggregate(f, maxChars: 4_000), "[0:01] hello\n[1:05] world")
    }

    func testAggregate_truncatesToBudget() {
        let f = [VideoSummary.FrameText(timeSeconds: 0, text: String(repeating: "x", count: 9_000))]
        XCTAssertLessThanOrEqual(VideoSummary.aggregate(f, maxChars: 500).count, 500)
    }
}
