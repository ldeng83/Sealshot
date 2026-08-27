import XCTest
@testable import Sealshot

/// `StripItem.merged` folds screen recordings into the Recent/Deleted strip
/// alongside indexed captures: video flags, future-date drop, and a recent-day
/// window computed over the union of both kinds.
final class StripItemMergeTests: XCTestCase {
    private let refNow = Date(timeIntervalSince1970: 1_700_000_000)
    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: refNow)!
    }
    private func capture(_ name: String, _ dayOffset: Int) -> StripItem {
        StripItem(url: URL(fileURLWithPath: "/caps/\(name).seal", isDirectory: true),
                  captureDate: day(dayOffset), displayName: name)
    }
    private func recording(_ name: String, _ dayOffset: Int, encrypted: Bool = false) -> RecordingItem {
        RecordingItem(url: URL(fileURLWithPath: "/recs/\(name).mov"),
                      modified: day(dayOffset), size: 1, isEncrypted: encrypted)
    }

    func test_interleavesByDateNewestFirst_andFlagsVideos() {
        let merged = StripItem.merged(
            captures: [capture("A", 0), capture("C", -2)],
            recordings: [recording("B", -1)],
            coveringDays: 30, now: refNow)
        XCTAssertEqual(merged.map(\.displayName), ["A", "B", "C"])
        XCTAssertEqual(merged.map(\.isVideo), [false, true, false])
    }

    func test_recordingCarriesVideoAndEncryptedFlags() {
        let merged = StripItem.merged(
            captures: [], recordings: [recording("locked", 0, encrypted: true)],
            coveringDays: 30, now: refNow)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].isVideo)
        XCTAssertTrue(merged[0].isEncrypted)
    }

    func test_dropsFutureDatedRows() {
        let merged = StripItem.merged(
            captures: [capture("today", 0)],
            recordings: [recording("future", 3)],   // clock skew
            coveringDays: 30, now: refNow)
        XCTAssertEqual(merged.map(\.displayName), ["today"])
    }

    func test_dayWindowSpansUnion_recordingDayCounts() {
        // coveringDays = 1 → only the single most-recent day with content. The
        // recording is today; the capture is 5 days back → only the recording
        // shows, proving recordings count toward the day window (not captures only).
        let merged = StripItem.merged(
            captures: [capture("oldCapture", -5)],
            recordings: [recording("todayVideo", 0)],
            coveringDays: 1, now: refNow)
        XCTAssertEqual(merged.map(\.displayName), ["todayVideo"])
    }
}
