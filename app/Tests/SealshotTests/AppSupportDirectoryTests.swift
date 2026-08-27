import XCTest
@testable import Sealshot

/// A test run must never touch the user's real Application Support directory.
///
/// It did: a full-suite run deleted and recreated the live
/// `~/Library/Application Support/Sealshot/libraryIndex.sqlite` underneath a
/// running Sealshot, leaving the app querying an unlinked file and showing an
/// empty Library, and injected rows pointing at the tests' own temp folders.
/// Fourteen call sites each resolved the directory for themselves, so there was
/// no single place to redirect. `AppSupportDirectory` is that place.
final class AppSupportDirectoryTests: XCTestCase {

    private var realSealshotDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sealshot", isDirectory: true)
    }

    func test_underXCTest_isNotTheUsersRealApplicationSupport() {
        XCTAssertNotEqual(
            AppSupportDirectory.sealshot.standardizedFileURL,
            realSealshotDirectory.standardizedFileURL,
            "tests must not write to the user's live Sealshot directory"
        )
    }

    func test_underXCTest_isNotEvenInsideTheRealDirectory() {
        // A subdirectory would still put test data in the user's library, and
        // anything that removes the parent would still take the real one with it.
        XCTAssertFalse(
            AppSupportDirectory.sealshot.standardizedFileURL.path
                .hasPrefix(realSealshotDirectory.standardizedFileURL.path),
            "the redirect must leave the user's directory entirely"
        )
    }

    func test_isStableWithinAProcess() {
        // Every store resolves this independently; if it moved between calls
        // they would each get a different directory and see none of each
        // other's writes.
        XCTAssertEqual(AppSupportDirectory.sealshot, AppSupportDirectory.sealshot)
    }

    func test_isWritable() {
        // The real directory is created on demand by the app; the redirect has
        // to offer the same guarantee or every store fails to persist.
        let probe = AppSupportDirectory.sealshot.appendingPathComponent("probe.txt")
        XCTAssertNoThrow(try "ok".write(to: probe, atomically: true, encoding: .utf8))
        try? FileManager.default.removeItem(at: probe)
    }

    func test_libraryIndexResolvesUnderIt() {
        // The store that actually corrupted the user's library.
        XCTAssertTrue(
            LibraryIndexStore.defaultDatabaseURL.standardizedFileURL.path
                .hasPrefix(AppSupportDirectory.sealshot.standardizedFileURL.path),
            "the capture index must follow the redirect"
        )
    }
}
