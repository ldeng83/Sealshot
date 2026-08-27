import XCTest
@testable import Sealshot

// `DeveloperToolsSupport` (pulled in transitively) also exports a `LibraryItem`,
// so the bare name is ambiguous in the test module. Pin it to ours.
private typealias LibraryItem = Sealshot.LibraryItem

final class LibrarySortTests: XCTestCase {

    private func item(_ name: String, date: TimeInterval, size: Int64,
                      category: ScreenshotCategory? = nil) -> LibraryItem {
        LibraryItem(url: URL(fileURLWithPath: "/x/\(name).seal"),
                    modified: Date(timeIntervalSince1970: date),
                    displayName: name, fileSize: size, category: category)
    }

    private func item(_ name: String, app: String?, w: Int, h: Int) -> LibraryItem {
        LibraryItem(url: URL(fileURLWithPath: "/lib/\(name).seal"),
                    modified: Date(timeIntervalSince1970: 0),
                    displayName: name, width: w, height: h, sourceApp: app)
    }

    private func names(_ items: [LibraryItem]) -> [String] { items.map(\.displayName) }

    func test_date_descending_newestFirst() {
        let items = [item("a", date: 100, size: 1), item("b", date: 300, size: 1),
                     item("c", date: 200, size: 1)]
        let out = sortLibraryItems(items, by: .init(field: .date, direction: .descending))
        XCTAssertEqual(names(out), ["b", "c", "a"])
    }

    func test_date_ascending_oldestFirst() {
        let items = [item("a", date: 100, size: 1), item("b", date: 300, size: 1),
                     item("c", date: 200, size: 1)]
        let out = sortLibraryItems(items, by: .init(field: .date, direction: .ascending))
        XCTAssertEqual(names(out), ["a", "c", "b"])
    }

    func test_name_ascending_caseInsensitive() {
        let items = [item("banana", date: 1, size: 1), item("Apple", date: 1, size: 1),
                     item("cherry", date: 1, size: 1)]
        let out = sortLibraryItems(items, by: .init(field: .name, direction: .ascending))
        XCTAssertEqual(names(out), ["Apple", "banana", "cherry"])
    }

    func test_size_descending_largestFirst() {
        let items = [item("a", date: 1, size: 100), item("b", date: 1, size: 300),
                     item("c", date: 1, size: 200)]
        let out = sortLibraryItems(items, by: .init(field: .size, direction: .descending))
        XCTAssertEqual(names(out), ["b", "c", "a"])
    }

    /// Equal sort keys fall back to capture-date descending (newest first).
    func test_tieBreak_isCaptureDateDescending() {
        let items = [item("old", date: 100, size: 5), item("new", date: 200, size: 5)]
        let out = sortLibraryItems(items, by: .init(field: .size, direction: .ascending))
        XCTAssertEqual(names(out), ["new", "old"], "equal size → newest capture first")
    }

    func test_emptyInput() {
        XCTAssertEqual(sortLibraryItems([], by: .init(field: .name, direction: .ascending)), [])
    }

    /// Items with identical capture dates (e.g. several files imported in the
    /// same second — `createdISO8601` is second-precision) must sort to the SAME
    /// order regardless of input order. The index query returns rows in an
    /// unspecified order that varies between the per-file metadata reloads, so a
    /// non-deterministic tie-break makes the grid visibly reshuffle until the
    /// last reload settles. A stable URL tie-break prevents that.
    func test_equalDates_deterministicOrder_independentOfInputOrder() {
        let a = item("a", date: 500, size: 1)
        let b = item("b", date: 500, size: 1)
        let c = item("c", date: 500, size: 1)
        let sort = LibrarySort(field: .date, direction: .descending)
        let out1 = names(sortLibraryItems([a, b, c], by: sort))
        let out2 = names(sortLibraryItems([c, a, b], by: sort))
        let out3 = names(sortLibraryItems([b, c, a], by: sort))
        XCTAssertEqual(out1, out2)
        XCTAssertEqual(out2, out3)
        XCTAssertEqual(out1, ["a", "b", "c"], "equal dates → stable URL order")
    }

    /// The same stability must hold when a secondary key (here, size) also ties.
    func test_equalKeysAndDates_deterministicOrder() {
        let a = item("a", date: 1, size: 7)
        let b = item("b", date: 1, size: 7)
        let sort = LibrarySort(field: .size, direction: .descending)
        XCTAssertEqual(names(sortLibraryItems([a, b], by: sort)),
                       names(sortLibraryItems([b, a], by: sort)))
    }

    func testSortByAppAscendingNilLast() {
        let items = [item("b", app: "Safari", w: 1, h: 1),
                     item("a", app: nil, w: 1, h: 1),
                     item("c", app: "Figma", w: 1, h: 1)]
        let sorted = sortLibraryItems(items, by: LibrarySort(field: .sourceApp, direction: .ascending))
        XCTAssertEqual(sorted.map(\.sourceApp), ["Figma", "Safari", nil])
    }

    func testSortByAppDescendingNilStillLast() {
        let items = [item("b", app: "Safari", w: 1, h: 1),
                     item("a", app: nil, w: 1, h: 1),
                     item("c", app: "Figma", w: 1, h: 1)]
        let sorted = sortLibraryItems(items, by: LibrarySort(field: .sourceApp, direction: .descending))
        XCTAssertEqual(sorted.map(\.sourceApp), ["Safari", "Figma", nil])
    }

    func testSortByDimensionsAreaNilLast() {
        let items = [item("hd", app: "x", w: 1920, h: 1080),   // 2.07M
                     item("big", app: "x", w: 4000, h: 3000),  // 12M
                     item("none", app: "x", w: 0, h: 0)]       // nil
        let sorted = sortLibraryItems(items, by: LibrarySort(field: .dimensions, direction: .descending))
        XCTAssertEqual(sorted.map(\.displayName), ["big", "hd", "none"])
    }

    func testNewFieldDefaults() {
        XCTAssertEqual(LibrarySortField.sourceApp.defaultDirection, .ascending)
        XCTAssertEqual(LibrarySortField.dimensions.defaultDirection, .descending)
        XCTAssertEqual(LibrarySortField.allCases.count, 5)
    }
}
