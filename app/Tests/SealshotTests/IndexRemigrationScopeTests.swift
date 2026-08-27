import XCTest
@testable import Sealshot

/// `needsSmartKeywordsRemigration` forces a full re-read of every manifest so
/// a pre-v4 index picks up the tags/smartKeywords split. It is set at open and
/// never cleared, and it gates the reconcile fast path — so it forced that
/// re-read on EVERY reconcile pass, not once. Field logs showed ~19,000
/// manifest reads in an afternoon where 320 were needed: 12 Library refreshes
/// x 320 files, repeated all session.
///
/// Two things went wrong, and these tests pin both.
final class IndexRemigrationScopeTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Remigration-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func row(_ path: String, tags: [String] = [], smart: [String] = []) -> CaptureIndexRow {
        CaptureIndexRow(path: path, folder: "/f", mtime: Date(timeIntervalSince1970: 10),
                        captureDate: Date(timeIntervalSince1970: 10),
                        userTitle: nil, title: "T", tags: tags,
                        smartKeywords: smart, fileSize: 123, width: 100, height: 100)
    }

    /// The trigger nobody expected: a brand-new index reads as version 0,
    /// which looks identical to a pre-v4 upgrade. Enabling Enhanced Security
    /// mints exactly such an index (an empty sealed one), so every enable used
    /// to condemn the rest of the session to full rescans.
    func test_freshEmptyIndexIsNotFlaggedForRemigration() throws {
        let db = try LibraryIndexDB(inMemoryFrom: nil)
        XCTAssertFalse(db.needsSmartKeywordsRemigration,
                       "an empty index has no stranded tags to migrate")
        XCTAssertEqual(db.userVersion, LibraryIndexDB.schemaVersion,
                       "a fresh index must be stamped current, not left at 0")
    }

    /// The same must hold for a file-backed index created from nothing.
    func test_freshFileBackedIndexIsNotFlagged() throws {
        let db = try LibraryIndexDB(url: dir.appendingPathComponent("new.sqlite"))
        XCTAssertFalse(db.needsSmartKeywordsRemigration)
    }

    /// The genuine upgrade path must still work: a database carrying rows at
    /// an older version DOES need the one-time re-read. Without this, "stop
    /// the rescan" would silently become "never migrate anyone".
    func test_populatedPreV4IndexIsStillFlagged() throws {
        let url = dir.appendingPathComponent("old.sqlite")
        // Build a populated index, then wind its version back to simulate v3.
        let seed = try LibraryIndexDB(url: url)
        try seed.upsert(row("/f/a.seal", tags: ["auto-keyword"]), ocrText: "x")
        seed.setUserVersionForTesting(3)
        _ = seed

        let reopened = try LibraryIndexDB(url: url)
        XCTAssertTrue(reopened.needsSmartKeywordsRemigration,
                      "a populated pre-v4 index must still get its one-time re-read")
    }

    /// And the migration's own SQL still runs for that user — the flag is not
    /// the only thing the upgrade does.
    func test_populatedPreV4IndexStillMovesStrandedTags() throws {
        let url = dir.appendingPathComponent("old2.sqlite")
        let seed = try LibraryIndexDB(url: url)
        try seed.upsert(row("/f/b.seal", tags: ["stranded"]), ocrText: "x")
        seed.setUserVersionForTesting(3)
        _ = seed

        let reopened = try LibraryIndexDB(url: url)
        let migrated = try reopened.rows(inFolder: "/f")
        XCTAssertEqual(migrated.first?.smartKeywords, ["stranded"],
                       "auto keywords stranded in tags move to smart_keywords")
        XCTAssertEqual(migrated.first?.tags, [], "user tags are left empty")
    }
}
