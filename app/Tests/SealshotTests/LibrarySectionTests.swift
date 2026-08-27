import XCTest
@testable import Sealshot

final class LibrarySectionTests: XCTestCase {
    func test_cases_areAllFiles_recents_collections_scratch_trash_lockedArchive() {
        XCTAssertEqual(LibrarySection.allCases,
                       [.allFiles, .recents, .collections, .scratch, .trash, .lockedArchive])
    }
    func test_removedRawValues_fallBackToAllFiles() {
        XCTAssertEqual(LibrarySection.from(rawValue: "Images"), .allFiles)
        XCTAssertEqual(LibrarySection.from(rawValue: "Videos"), .allFiles)
        XCTAssertEqual(LibrarySection.from(rawValue: "Trash"), .trash)
    }
    func test_lockedArchive_rawValue_roundTrips() {
        XCTAssertEqual(LibrarySection.lockedArchive.rawValue, "Locked Archive")
        XCTAssertEqual(LibrarySection.from(rawValue: "Locked Archive"), .lockedArchive)
    }
    func test_isTrash() {
        XCTAssertTrue(LibrarySection.trash.isTrash)
        XCTAssertFalse(LibrarySection.collections.isTrash)
        XCTAssertFalse(LibrarySection.lockedArchive.isTrash)
    }
    func test_isLockedArchive() {
        XCTAssertTrue(LibrarySection.lockedArchive.isLockedArchive)
        XCTAssertFalse(LibrarySection.trash.isLockedArchive)
        XCTAssertFalse(LibrarySection.collections.isLockedArchive)
    }
    func test_symbol_isArchivebox() {
        XCTAssertEqual(LibrarySection.lockedArchive.symbol, "archivebox")
    }
}
