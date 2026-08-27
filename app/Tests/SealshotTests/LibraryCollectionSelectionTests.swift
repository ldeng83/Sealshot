import XCTest
@testable import Sealshot

final class LibraryCollectionSelectionTests: XCTestCase {
    func test_none_matchesAll() {
        XCTAssertTrue(LibraryCollectionSelection.none.matches(isFavorite: false, collectionIDs: []))
    }
    func test_favorites_matchesFavoriteOnly() {
        XCTAssertTrue(LibraryCollectionSelection.favorites.matches(isFavorite: true, collectionIDs: []))
        XCTAssertFalse(LibraryCollectionSelection.favorites.matches(isFavorite: false, collectionIDs: [UUID()]))
    }
    func test_collection_matchesMembership() {
        let a = UUID(); let b = UUID()
        XCTAssertTrue(LibraryCollectionSelection.collection(a).matches(isFavorite: false, collectionIDs: [a, b]))
        XCTAssertFalse(LibraryCollectionSelection.collection(a).matches(isFavorite: true, collectionIDs: [b]))
    }
}
