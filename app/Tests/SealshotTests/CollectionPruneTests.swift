import XCTest
@testable import Sealshot

// DeveloperToolsSupport also exports a LibraryItem; pin to ours.
private typealias LibraryItem = Sealshot.LibraryItem

final class CollectionPruneTests: XCTestCase {

    // Minimal LibraryItem builder — only url and collectionIDs matter for these tests.
    private func item(_ path: String, _ ids: [UUID]) -> LibraryItem {
        LibraryItem(
            url: URL(fileURLWithPath: path),
            modified: Date(timeIntervalSince1970: 1),
            displayName: path,
            collectionIDs: ids
        )
    }

    // MARK: – collectionMemberURLs

    func test_memberURLs_returnsOnlyItemsContainingID() {
        let a = UUID(); let b = UUID()
        let items = [item("/x/1", [a]), item("/x/2", [a, b]), item("/x/3", [b])]
        let result = Set(collectionMemberURLs(items, collectionID: a).map(\.path))
        XCTAssertEqual(result, ["/x/1", "/x/2"])
    }

    func test_memberURLs_returnsEmptyWhenNoItemContainsID() {
        let a = UUID(); let b = UUID()
        let items = [item("/x/1", [a]), item("/x/2", [a])]
        XCTAssertTrue(collectionMemberURLs(items, collectionID: b).isEmpty)
    }

    func test_memberURLs_itemInMultipleCollectionsReturnedForEach() {
        let a = UUID(); let b = UUID()
        let items = [item("/x/shared", [a, b])]
        XCTAssertEqual(collectionMemberURLs(items, collectionID: a).map(\.path), ["/x/shared"])
        XCTAssertEqual(collectionMemberURLs(items, collectionID: b).map(\.path), ["/x/shared"])
    }
}
