import XCTest
@testable import Sealshot

final class LibraryItemInfoTests: XCTestCase {
    private func base() -> LibraryItemInfo {
        LibraryItemInfo(
            name: "Shot.seal", generatedSummary: "A summary", tags: ["a","b"],
            category: nil, isFavorite: false, isVideo: false,
            width: 1920, height: 1080,
            capturedDisplay: "Jun 1, 2026", modifiedDisplay: "Jun 1, 2026",
            sourceApp: "Safari", captureKindLabel: "Scrolling capture",
            captureModeLabel: "Window", pageDomain: "example.com",
            durationDisplay: nil, contentTypeLabel: "Web page",
            sizeDisplay: "2.4 MB")
    }

    func testSummaryThreeStates() {
        var v = base()
        // nil override → generated.
        XCTAssertEqual(v.summary, "A summary")
        // text override wins.
        v.userSummary = "My own words"
        XCTAssertEqual(v.summary, "My own words")
        // Empty / whitespace-only override = deliberately suppressed → blank,
        // NOT a fall-back to generated.
        v.userSummary = ""
        XCTAssertEqual(v.summary, "")
        v.userSummary = "   \n"
        XCTAssertEqual(v.summary, "")
    }

    func testDetailRowsOrderAndDimensions() {
        let rows = base().detailRows
        XCTAssertEqual(rows.first?.label, "Dimensions")
        XCTAssertEqual(rows.first?.value, "1920 × 1080")
        XCTAssertEqual(rows.map(\.label).last, "Size")
    }

    func testModifiedHiddenWhenEqualCaptured() {
        XCTAssertFalse(base().detailRows.contains { $0.label == "Modified" })
        var v = base(); v.modifiedDisplay = "Jun 2, 2026"
        XCTAssertTrue(v.detailRows.contains { $0.label == "Modified" })
    }

    func testOmitsEmptyOptionalRows() {
        var v = base(); v.sourceApp = ""; v.pageDomain = ""; v.captureModeLabel = ""
        let labels = v.detailRows.map(\.label)
        XCTAssertFalse(labels.contains("Source app"))
        XCTAssertFalse(labels.contains("Website"))
        XCTAssertFalse(labels.contains("Capture type"))
    }

    func testDurationOnlyForVideo() {
        var img = base(); img.durationDisplay = "0:45"
        XCTAssertFalse(img.detailRows.contains { $0.label == "Duration" })
        var vid = base(); vid.isVideo = true; vid.durationDisplay = "0:45"
        XCTAssertEqual(vid.detailRows.first { $0.label == "Duration" }?.value, "0:45")
    }
}
