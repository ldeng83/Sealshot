import XCTest
@testable import Sealshot

/// `reconcileDateAction` decides how a scanned capture's date is sourced during
/// index reconcile. The regression it guards: an encrypted `.seal` whose
/// manifest is momentarily unreadable must NEVER be stamped with a filesystem
/// date (mtime/creationDate), which re-saves bump — floating it to the front of
/// the strip. It defers instead.
final class ReconcileActionTests: XCTestCase {

    func test_manifestReadable_indexesFromManifest() {
        XCTAssertEqual(
            reconcileDateAction(manifestReadable: true, isSeal: true, hasExistingRow: true),
            .indexFromManifest)
        XCTAssertEqual(
            reconcileDateAction(manifestReadable: true, isSeal: true, hasExistingRow: false),
            .indexFromManifest)
    }

    func test_unreadableSeal_withRow_keepsExistingDate() {
        XCTAssertEqual(
            reconcileDateAction(manifestReadable: false, isSeal: true, hasExistingRow: true),
            .keepExistingDate)
    }

    func test_unreadableSeal_noRow_indexesProvisionallyUntilReadable() {
        // Don't hide it (that needs a tab switch to appear) and don't let a
        // filesystem date stick — index a provisional, re-read-me row.
        XCTAssertEqual(
            reconcileDateAction(manifestReadable: false, isSeal: true, hasExistingRow: false),
            .provisionalUntilReadable)
    }

    func test_legacyPng_usesStatDate() {
        XCTAssertEqual(
            reconcileDateAction(manifestReadable: false, isSeal: false, hasExistingRow: false),
            .legacyStatDate)
        XCTAssertEqual(
            reconcileDateAction(manifestReadable: false, isSeal: false, hasExistingRow: true),
            .legacyStatDate)
    }
}
