import XCTest
@testable import Sealshot

/// Unit tests for the one-time smart-keywords re-migration version gate.
///
/// The migration detects DB instances that predate the tags/smartKeywords
/// split (SQLite `user_version` < `LibraryIndexDB.schemaVersion`) and flags
/// them for a full re-reconcile so the per-manifest `CaptureMetadata` decode
/// migration can move old combined auto-tags out of the `tags` index column
/// and into `smartKeywords`, leaving user `tags` correct.
final class LibraryIndexRemigrationTests: XCTestCase {

    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryIndexRemigrationTests-\(UUID().uuidString)")
            .appendingPathComponent("index.sqlite")
    }

    // MARK: file-backed DB

    /// A brand-new DB starts at SQLite user_version = 0, which *looks* like a
    /// pre-v4 database but isn't one — it has no rows, so there are no
    /// stranded auto-tags to migrate. It is stamped to schemaVersion on first
    /// open and NOT flagged.
    ///
    /// This assertion was inverted (2026-08-05). It previously required a
    /// fresh DB to be flagged, which was the implementation's behaviour rather
    /// than the migration's purpose — this class's own docstring says the gate
    /// exists to catch DBs that "predate the tags/smartKeywords split". The
    /// flag gates the reconcile fast path and is never cleared, so flagging a
    /// fresh DB forced a re-read of every manifest on every reconcile for the
    /// whole session: measured at ~19,000 manifest reads in one afternoon
    /// where 320 were needed. Flagging an empty DB also achieves nothing —
    /// the fast path needs an existing row to skip, so an empty index re-reads
    /// on its first pass regardless.
    func test_firstOpen_doesNotFlagRemigration_butBumpsUserVersion() throws {
        let url = tempDBURL()
        let db = try LibraryIndexDB(url: url)
        XCTAssertFalse(db.needsSmartKeywordsRemigration,
                       "an empty DB has no stranded tags — flagging it only poisons the fast path")
        XCTAssertEqual(db.userVersion, LibraryIndexDB.schemaVersion,
                       "user_version must be bumped to schemaVersion on first open")
    }

    /// Reopening the same file after user_version was already set to
    /// schemaVersion must NOT re-flag remigration — one-shot guarantee.
    func test_secondOpen_doesNotFlagRemigration() throws {
        let url = tempDBURL()
        _ = try LibraryIndexDB(url: url) // first open: bumps user_version
        let db2 = try LibraryIndexDB(url: url) // second open: already at schemaVersion
        XCTAssertFalse(db2.needsSmartKeywordsRemigration,
                       "Already-migrated DB must not re-flag remigration")
        XCTAssertEqual(db2.userVersion, LibraryIndexDB.schemaVersion)
    }

    // MARK: in-memory DB (encrypted-index path)

    /// New in-memory DB (nil data — the empty encrypted index minted the first
    /// time Enhanced Security is enabled) starts at user_version 0 → same
    /// behaviour as a new file DB: stamped, not flagged.
    ///
    /// Inverted alongside `test_firstOpen_…` above, and this is the path that
    /// actually bit: every time encryption was switched on, the empty sealed
    /// index was flagged and the rest of that session re-read all 320
    /// manifests on every Library refresh.
    func test_inMemory_newDB_doesNotFlagRemigration() throws {
        let db = try LibraryIndexDB(inMemoryFrom: nil)
        XCTAssertFalse(db.needsSmartKeywordsRemigration,
                       "enabling encryption mints this DB — flagging it rescans all session")
        XCTAssertEqual(db.userVersion, LibraryIndexDB.schemaVersion)
    }

    /// Deserializing a snapshot that already carries user_version = schemaVersion
    /// must NOT flag remigration — the migration is idempotent.
    func test_inMemory_existingMigratedDB_doesNotFlagRemigration() throws {
        // First open sets user_version = schemaVersion and serializes.
        let db1 = try LibraryIndexDB(inMemoryFrom: nil)
        let snapshot = try db1.serialize()
        // Deserialize into a new instance — user_version carries through the blob.
        let db2 = try LibraryIndexDB(inMemoryFrom: snapshot)
        XCTAssertFalse(db2.needsSmartKeywordsRemigration,
                       "Migrated in-memory snapshot must not re-flag remigration")
        XCTAssertEqual(db2.userVersion, LibraryIndexDB.schemaVersion)
    }

    // MARK: schemaVersion invariant

    func test_schemaVersion_isPositive() {
        XCTAssertGreaterThan(LibraryIndexDB.schemaVersion, 0,
                             "schemaVersion must be a positive integer")
    }
}
