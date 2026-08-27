import XCTest
@testable import Sealshot

/// Row-based item assembly: indexed rows + FTS OCR hits → LibraryItems.
final class LibraryRowItemsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    private func row(_ name: String, folder: String = "/shots",
                     date: Date? = nil, userTitle: String? = nil,
                     title: String = "", tags: [String] = []) -> CaptureIndexRow {
        let d = date ?? now
        return CaptureIndexRow(path: "\(folder)/\(name)", folder: folder,
                               mtime: d, captureDate: d,
                               userTitle: userTitle, title: title, tags: tags)
    }

    // MARK: sections + sorting

    func test_recents_excludesOlderThanSevenDays_includesBoundary() {
        let rows = [row("new.seal", date: daysAgo(1)),
                    row("edge.seal", date: daysAgo(7)),
                    row("old.seal", date: daysAgo(8))]
        let items = makeLibraryItems(rows: rows, section: .recents, search: "", now: now)
        XCTAssertEqual(items.map(\.filename), ["new.seal", "edge.seal"])
    }

    func test_allShotsAndTrash_keepEverything_sortedNewestFirst() {
        let rows = [row("older.seal", date: daysAgo(400)),
                    row("newer.seal", date: daysAgo(1))]
        XCTAssertEqual(
            makeLibraryItems(rows: rows, section: .allFiles, search: "", now: now)
                .map(\.filename),
            ["newer.seal", "older.seal"])
        XCTAssertEqual(
            makeLibraryItems(rows: rows, section: .trash, search: "", now: now).count, 2)
    }

    // MARK: search

    func test_search_substringOnFilenameTitleUserTitleAndTags() {
        let rows = [row("Report.png"),
                    row("a.seal", title: "Checkout Flow"),
                    row("b.seal", userTitle: "My Checkout"),
                    row("c.seal", tags: ["checkout", "cart"]),
                    row("d.seal", title: "unrelated")]
        let hits = makeLibraryItems(rows: rows, section: .allFiles,
                                    search: "checkout", now: now)
        XCTAssertEqual(Set(hits.map(\.filename)), ["a.seal", "b.seal", "c.seal"])

        let byName = makeLibraryItems(rows: rows, section: .allFiles,
                                      search: "rep", now: now)
        XCTAssertEqual(byName.map(\.filename), ["Report.png"])
    }

    func test_ocrHit_carriesSnippet_andOnlyMatchedRowsSurvive() {
        let rows = [row("a.seal", date: daysAgo(1)), row("b.seal", date: daysAgo(2))]
        let items = makeLibraryItems(
            rows: rows, section: .allFiles, search: "zzz", now: now,
            ocrHits: ["/shots/a.seal": "…around the hit…"])
        XCTAssertEqual(items.map(\.matchSnippet), ["…around the hit…"])
    }

    func test_directHitOnUserTitle_beatsOCRSnippet() {
        let rows = [row("a.seal", userTitle: "zzz report")]
        let items = makeLibraryItems(
            rows: rows, section: .allFiles, search: "zzz", now: now,
            ocrHits: ["/shots/a.seal": "snippet"])
        XCTAssertNil(items[0].matchSnippet, "direct matches show no snippet")
    }

    func test_emptySearch_keepsAll_noSnippets() {
        let rows = [row("a.seal")]
        let items = makeLibraryItems(rows: rows, section: .allFiles, search: "",
                                     now: now, ocrHits: ["/shots/a.seal": "x"])
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].matchSnippet)
    }

    // MARK: display

    func test_displayName_userTitleWinsElseFilename() {
        let rows = [row("a.seal", userTitle: "Renamed"),
                    row("plain.seal"),
                    row("blank.seal", userTitle: "   ")]
        let items = makeLibraryItems(rows: rows, section: .allFiles, search: "", now: now)
        XCTAssertEqual(Set(items.map(\.displayName)), ["Renamed", "plain", "blank"])
    }

    /// A `.seal` is a single-file container now, not a directory package, so
    /// its URLs are FILE urls — and must stay so, because selection, tile
    /// diffing and Show-in-Library all compare them against the URLs
    /// `contentsOfDirectory` hands back. A stray directory-form URL compares
    /// unequal to the identical path and silently breaks all three.
    func test_sealURLs_areFileURLs() {
        let items = makeLibraryItems(rows: [row("a.seal")], section: .allFiles,
                                     search: "", now: now)
        XCTAssertFalse(items[0].url.hasDirectoryPath,
                       ".seal item URLs must match contentsOfDirectory's file URLs")
    }

    func test_pngURLs_areFileURLs() {
        let items = makeLibraryItems(rows: [row("a.png")], section: .allFiles,
                                     search: "", now: now)
        XCTAssertFalse(items[0].url.hasDirectoryPath)
    }
}
