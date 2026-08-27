import XCTest
@testable import Sealshot

final class CollectionTileModelTests: XCTestCase {
    private func item(_ name: String, _ daysAgo: Double, fav: Bool = false, cols: [UUID] = []) -> Sealshot.LibraryItem {
        Sealshot.LibraryItem(url: URL(fileURLWithPath: "/x/\(name).seal"),
                    modified: Date(timeIntervalSince1970: 1_000_000 - daysAgo*86400),
                    displayName: name, fileSize: 0, category: nil, isFavorite: fav,
                    status: .new, matchSnippet: nil, isVideo: false, durationSeconds: nil,
                    collectionIDs: cols)
    }
    func test_representativeMember_isNewestInCollection() {
        let a = UUID()
        let items = [item("old", 5, cols: [a]), item("new", 1, cols: [a]), item("other", 0, cols: [])]
        XCTAssertEqual(representativeMember(items, collectionID: a)?.displayName, "new")
    }
    func test_favoriteRepresentative_isNewestFavorite() {
        let items = [item("f-old", 5, fav: true), item("f-new", 2, fav: true), item("nofav", 0)]
        XCTAssertEqual(favoriteRepresentative(items)?.displayName, "f-new")
    }
    func test_representativeMember_nilWhenEmpty() {
        XCTAssertNil(representativeMember([item("x", 1)], collectionID: UUID()))
    }
}
