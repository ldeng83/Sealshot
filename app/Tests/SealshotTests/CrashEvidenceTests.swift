import XCTest
@testable import Sealshot

final class CrashEvidenceTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolve the real canonical path (e.g. /var → /private/var on macOS) so
        // URLs built from this directory match what contentsOfDirectory(at:) returns.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(dir.path, &buf) != nil {
            return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
        }
        return dir
    }

    private func makeMarker(launchDate: Date = Date(timeIntervalSince1970: 1_000_000)) -> SessionMarker {
        SessionMarker(launchDate: launchDate, appVersion: "0.3.0 (42)", pid: 123)
    }

    // MARK: SessionMarkerStore

    func testWriteFresh_thenReadStale_roundTrips() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionMarkerStore(directory: dir)
        let marker = makeMarker()
        store.writeFresh(marker)
        XCTAssertEqual(store.readStale(), marker)
    }

    func testClearOnCleanQuit_leavesNoMarker() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionMarkerStore(directory: dir)
        store.writeFresh(makeMarker())
        store.clearOnCleanQuit()
        XCTAssertNil(store.readStale())
    }

    func testCorruptMarker_readsAsNil() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionMarkerStore(directory: dir)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertNil(store.readStale())
    }

    func testMissingDirectory_readsAsNil_andWriteCreatesIt() {
        let dir = tempDir().appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionMarkerStore(directory: dir)
        XCTAssertNil(store.readStale())
        store.writeFresh(makeMarker())
        XCTAssertNotNil(store.readStale())
    }

    // MARK: CrashReportLocator

    private let direct = "com.seal-shot.sealshot.direct"

    /// Write a fake .ips: first line is the JSON header macOS writes,
    /// remainder is payload. Sets the file's modification date.
    @discardableResult
    private func writeIPS(named name: String, in dir: URL,
                          bundleID: String, date: Date,
                          header: String? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let line = header ?? "{\"app_name\":\"Sealshot\",\"bundleID\":\"\(bundleID)\"}"
        try Data("\(line)\n{\"payload\":true}".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    func testStaleMarker_withNewerReport_returnsIt() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let launch = Date(timeIntervalSince1970: 1_000_000)
        let url = try writeIPS(named: "Sealshot-2026-06-10-101010.ips", in: dir,
                               bundleID: direct, date: launch.addingTimeInterval(60))
        let locator = CrashReportLocator(reportsDirectory: dir, bundleID: direct)
        XCTAssertEqual(locator.reportMatching(makeMarker(launchDate: launch)), url)
    }

    func testNewestReportWins() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let launch = Date(timeIntervalSince1970: 1_000_000)
        try writeIPS(named: "Sealshot-old.ips", in: dir,
                     bundleID: direct, date: launch.addingTimeInterval(60))
        let newest = try writeIPS(named: "Sealshot-new.ips", in: dir,
                                  bundleID: direct, date: launch.addingTimeInterval(600))
        let locator = CrashReportLocator(reportsDirectory: dir, bundleID: direct)
        XCTAssertEqual(locator.reportMatching(makeMarker(launchDate: launch)), newest)
    }

    func testNoReports_returnsNil() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let locator = CrashReportLocator(reportsDirectory: dir, bundleID: direct)
        XCTAssertNil(locator.reportMatching(makeMarker()))
    }

    func testReportOlderThanLaunch_returnsNil() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let launch = Date(timeIntervalSince1970: 1_000_000)
        try writeIPS(named: "Sealshot-stale.ips", in: dir,
                     bundleID: direct, date: launch.addingTimeInterval(-60))
        let locator = CrashReportLocator(reportsDirectory: dir, bundleID: direct)
        XCTAssertNil(locator.reportMatching(makeMarker(launchDate: launch)))
    }

    func testWrongBundleID_returnsNil() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let launch = Date(timeIntervalSince1970: 1_000_000)
        try writeIPS(named: "Sealshot-mas.ips", in: dir,
                     bundleID: "com.seal-shot.sealshot",  // MAS build's crash
                     date: launch.addingTimeInterval(60))
        let locator = CrashReportLocator(reportsDirectory: dir, bundleID: direct)
        XCTAssertNil(locator.reportMatching(makeMarker(launchDate: launch)))
    }

    func testOtherProcessAndNonIPS_ignored() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let launch = Date(timeIntervalSince1970: 1_000_000)
        try writeIPS(named: "Safari-2026.ips", in: dir,
                     bundleID: direct, date: launch.addingTimeInterval(60))
        try writeIPS(named: "Sealshot-notes.txt", in: dir,
                     bundleID: direct, date: launch.addingTimeInterval(60))
        let locator = CrashReportLocator(reportsDirectory: dir, bundleID: direct)
        XCTAssertNil(locator.reportMatching(makeMarker(launchDate: launch)))
    }

    func testCorruptHeader_skipped_othersStillConsidered() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let launch = Date(timeIntervalSince1970: 1_000_000)
        try writeIPS(named: "Sealshot-corrupt.ips", in: dir, bundleID: direct,
                     date: launch.addingTimeInterval(600), header: "not json {")
        let good = try writeIPS(named: "Sealshot-good.ips", in: dir,
                                bundleID: direct, date: launch.addingTimeInterval(60))
        let locator = CrashReportLocator(reportsDirectory: dir, bundleID: direct)
        XCTAssertEqual(locator.reportMatching(makeMarker(launchDate: launch)), good)
    }

    func testMissingReportsDirectory_returnsNil() {
        let missing = tempDir().appendingPathComponent("nope", isDirectory: true)
        let locator = CrashReportLocator(reportsDirectory: missing, bundleID: direct)
        XCTAssertNil(locator.reportMatching(makeMarker()))
    }

    func testHeaderWithoutNewline_stillMatches() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let launch = Date(timeIntervalSince1970: 1_000_000)
        let url = dir.appendingPathComponent("Sealshot-nonewline.ips")
        try Data("{\"bundleID\":\"com.seal-shot.sealshot.direct\"}".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: launch.addingTimeInterval(60)], ofItemAtPath: url.path)
        let locator = CrashReportLocator(reportsDirectory: dir, bundleID: direct)
        // No trailing newline: the whole file IS the first line, and it is
        // valid JSON with a matching bundleID — so this SHOULD match.
        XCTAssertEqual(locator.reportMatching(makeMarker(launchDate: launch)), url)
    }
}
