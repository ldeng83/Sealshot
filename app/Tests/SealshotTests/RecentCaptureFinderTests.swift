import XCTest
@testable import Sealshot

final class RecentCaptureFinderTests: XCTestCase {

    // Fixed mid-day reference so calendar-day bucketing is stable in any
    // timezone the test machine runs in.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/Sealshot/\(name).png")
    }
    private let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    func testFilter_keepsCapturesFromMostRecentCaptureDays() {
        // 8 distinct capture days — only the 7 most recent days survive.
        let candidates: [(URL, Date)] = (0..<8).map {
            (url("d\($0)"), daysAgo(Double($0)))
        }
        let result = filterRecentCaptures(candidates, coveringDays: 7, calendar: utc)
        XCTAssertEqual(result.map { $0.lastPathComponent },
                       (0..<7).map { "d\($0).png" })
    }

    func testFilter_oldCapturesStillShown_whenNoRecentOnes() {
        // The user's bug: a library whose newest capture is weeks old must
        // still fill the strip — the window is days WITH captures, not
        // calendar days back from now.
        let candidates: [(URL, Date)] = [
            (url("a"), daysAgo(30)),
            (url("b"), daysAgo(31)),
            (url("c"), daysAgo(45)),
        ]
        let result = filterRecentCaptures(candidates, coveringDays: 7, calendar: utc)
        XCTAssertEqual(result.map { $0.lastPathComponent },
                       ["a.png", "b.png", "c.png"])
    }

    func testFilter_multipleCapturesOnOneDay_allKept() {
        // Two shots on the same (old) day count as ONE day of the window.
        let candidates: [(URL, Date)] = [
            (url("morning"), daysAgo(20.4)),
            (url("evening"), daysAgo(20.1)),
            (url("older"),   daysAgo(40)),
        ]
        let result = filterRecentCaptures(candidates, coveringDays: 2, calendar: utc)
        XCTAssertEqual(result.map { $0.lastPathComponent },
                       ["evening.png", "morning.png", "older.png"])
    }

    func testFilter_sortsNewestFirst() {
        let candidates: [(URL, Date)] = [
            (url("old"),    daysAgo(5)),
            (url("newest"), daysAgo(0.1)),
            (url("middle"), daysAgo(2)),
        ]
        let result = filterRecentCaptures(candidates, coveringDays: 7, calendar: utc)
        XCTAssertEqual(result.map { $0.lastPathComponent },
                       ["newest.png", "middle.png", "old.png"])
    }

    func testFilter_emptyInput_returnsEmpty() {
        XCTAssertTrue(filterRecentCaptures([], coveringDays: 7, calendar: utc).isEmpty)
    }

    func test_findRecentCaptures_includesSealPackages() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("RCFTest-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // A .png file (regular file)
        let png = dir.appendingPathComponent("a.png")
        try Data([0x00]).write(to: png)

        // A .seal package (directory)
        let seal = dir.appendingPathComponent("b.seal")
        try fm.createDirectory(at: seal, withIntermediateDirectories: true)
        try Data([0x00]).write(to: seal.appendingPathComponent("placeholder"))

        let urls = findRecentCaptures(in: dir, coveringDays: 7)
        let names = urls.map { $0.lastPathComponent }
        XCTAssertTrue(names.contains("a.png"), "expected a.png in \(names)")
        XCTAssertTrue(names.contains("b.seal"), "expected b.seal in \(names)")
    }

    // MARK: - Index-listing fallback

    func testNeedsDirectScan_whenIndexFailedToOpen() {
        XCTAssertTrue(stripNeedsDirectScan(indexed: nil),
                      "a nil listing means the index DB never opened")
    }

    func testNeedsDirectScan_whenIndexOpensButHoldsNoRows() {
        // The bug: an index that opens cleanly but is EMPTY (never built, just
        // reset, or rebuilt after an encryption-mode change) returned [], which
        // is non-nil — so the direct-scan fallback was skipped and the strip
        // went blank while captures sat on disk.
        XCTAssertTrue(stripNeedsDirectScan(indexed: []),
                      "an empty listing must fall back to the disk scan")
    }

    func testNeedsDirectScan_falseWhenIndexHasRows() {
        let item = StripItem(url: url("a"), captureDate: now, displayName: "a")
        XCTAssertFalse(stripNeedsDirectScan(indexed: [item]),
                       "a populated index must be trusted — no extra disk scan")
    }

    // MARK: - Refresh on index change

    private func folder(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/Sealshot/\(name)", isDirectory: true)
    }

    func testShouldRefresh_whenTheChangedFolderIsTheWatchedOne() {
        XCTAssertTrue(stripShouldRefresh(forIndexChangeIn: folder("shots"),
                                         watching: folder("shots")))
    }

    func testShouldRefresh_falseForAnUnrelatedFolder() {
        // The Deleted strip watches <save>/Deleted — a reconcile of the save
        // folder must not make it reload.
        XCTAssertFalse(stripShouldRefresh(forIndexChangeIn: folder("shots"),
                                          watching: folder("shots/Deleted")))
    }

    func testShouldRefresh_whenTheChangeCarriesNoFolder() {
        // Unknown scope — refresh rather than risk staying stale.
        XCTAssertTrue(stripShouldRefresh(forIndexChangeIn: nil,
                                         watching: folder("shots")))
    }

    func testShouldRefresh_ignoresTrailingSlashDifferences() {
        // A folder read back from UserDefaults carries a trailing slash the
        // picker's URL doesn't (see CaptureConfig.saveFolder) — the same folder
        // in two spellings must still match.
        XCTAssertTrue(stripShouldRefresh(
            forIndexChangeIn: URL(fileURLWithPath: "/tmp/Sealshot/shots/"),
            watching: URL(fileURLWithPath: "/tmp/Sealshot/shots")))
    }
}
