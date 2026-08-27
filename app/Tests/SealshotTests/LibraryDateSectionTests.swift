import XCTest
@testable import Sealshot

final class LibraryDateSectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func item(_ name: String, ago: TimeInterval) -> Sealshot.LibraryItem {
        Sealshot.LibraryItem(url: URL(fileURLWithPath: "/lib/\(name).seal"),
                             modified: now.addingTimeInterval(-ago), displayName: name)
    }

    func testBuckets() {
        XCTAssertEqual(libraryDateSection(for: now.addingTimeInterval(-3600), now: now), "Today")
        XCTAssertEqual(libraryDateSection(for: now.addingTimeInterval(-3*86_400), now: now), "Last 7 days")
        XCTAssertEqual(libraryDateSection(for: now.addingTimeInterval(-30*86_400), now: now), "Earlier")
    }

    func testGroupingKeepsOrderAndSections() {
        let items = [item("a", ago: 3600), item("b", ago: 3*86_400), item("c", ago: 30*86_400)]
        let groups = groupedByDate(items, now: now)
        XCTAssertEqual(groups.map(\.label), ["Today", "Last 7 days", "Earlier"])
        XCTAssertEqual(groups[0].items.map(\.displayName), ["a"])
    }

    func testEmptySectionsOmitted() {
        let items = [item("a", ago: 3600)]   // only Today
        let groups = groupedByDate(items, now: now)
        XCTAssertEqual(groups.map(\.label), ["Today"])
    }
}
