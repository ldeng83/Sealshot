import XCTest
@testable import Sealshot

final class LibraryTagsTests: XCTestCase {
    func test_sortsTagsCaseInsensitiveAlphabetical() {
        let raw = [("Zebra", 1), ("apple", 5), ("Banana", 2)]
            .map { (tag: $0.0, count: $0.1) }
        let sorted = sortedTagsAlphabetically(raw)
        XCTAssertEqual(sorted.map { $0.tag }, ["apple", "Banana", "Zebra"])
        XCTAssertEqual(sorted.first?.count, 5)   // count travels with the tag
    }

    func test_andPredicate_requiresAllSelectedTags() {
        let item = ["receipt", "2024", "invoice"]
        XCTAssertTrue(libraryItemMatchesTags(itemTags: item, selected: ["receipt", "2024"]))
        XCTAssertFalse(libraryItemMatchesTags(itemTags: item, selected: ["receipt", "draft"]))
    }

    func test_andPredicate_emptySelectionMatchesEverything() {
        XCTAssertTrue(libraryItemMatchesTags(itemTags: [], selected: []))
        XCTAssertTrue(libraryItemMatchesTags(itemTags: ["x"], selected: []))
    }
}
