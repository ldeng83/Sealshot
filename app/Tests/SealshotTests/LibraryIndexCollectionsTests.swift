import XCTest
import SQLite3
@testable import Sealshot

/// The capture index persists collection_ids (UUID list) and migrates
/// pre-existing databases that lack the column.
final class LibraryIndexCollectionsTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-coll-\(UUID().uuidString).sqlite")
    }

    func test_upsert_and_read_collectionIDs_roundTrip() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let db = try LibraryIndexDB(url: url)
        let a = UUID(); let b = UUID()
        let row = CaptureIndexRow(
            path: "/x/a.seal", folder: "/x",
            mtime: Date(timeIntervalSince1970: 1),
            captureDate: Date(timeIntervalSince1970: 1),
            userTitle: nil, title: "A",
            tags: [],
            collectionIDs: [a, b])
        try db.upsert(row, ocrText: "")
        let read = try db.rows(inFolder: "/x").first
        XCTAssertEqual(Set(read?.collectionIDs ?? []), [a, b])
    }

    func test_empty_collectionIDs_roundTripsAsEmpty() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let db = try LibraryIndexDB(url: url)
        let row = CaptureIndexRow(
            path: "/x/b.seal", folder: "/x",
            mtime: Date(timeIntervalSince1970: 1),
            captureDate: Date(timeIntervalSince1970: 1),
            userTitle: nil, title: "B",
            tags: [])
        try db.upsert(row, ocrText: "")
        XCTAssertEqual(try db.rows(inFolder: "/x").first?.collectionIDs, [])
    }

    /// A database created by the OLD schema (no collection_ids column) must be
    /// migrated transparently on open, then read back with an empty collectionIDs.
    func test_migration_adds_column_to_existing_db() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        createOldSchema(at: url)
        // Opening through the real type must migrate (add the column) without error.
        let db = try LibraryIndexDB(url: url)
        let row = CaptureIndexRow(
            path: "/x/c.seal", folder: "/x",
            mtime: Date(timeIntervalSince1970: 1),
            captureDate: Date(timeIntervalSince1970: 1),
            userTitle: nil, title: "C",
            tags: [])
        try db.upsert(row, ocrText: "")
        XCTAssertEqual(try db.rows(inFolder: "/x").first?.collectionIDs ?? [], [])
    }

    func test_collectionMemberRows_filtersByID() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let db = try LibraryIndexDB(url: url)
        let a = UUID(); let b = UUID()
        try db.upsert(CaptureIndexRow(path: "/x/1.seal", folder: "/x",
            mtime: Date(timeIntervalSince1970: 1), captureDate: Date(timeIntervalSince1970: 1),
            userTitle: nil, title: "one", tags: [], collectionIDs: [a]), ocrText: "")
        try db.upsert(CaptureIndexRow(path: "/x/2.seal", folder: "/x",
            mtime: Date(timeIntervalSince1970: 2), captureDate: Date(timeIntervalSince1970: 2),
            userTitle: nil, title: "two", tags: [], collectionIDs: [a, b]), ocrText: "")
        try db.upsert(CaptureIndexRow(path: "/x/3.seal", folder: "/x",
            mtime: Date(timeIntervalSince1970: 3), captureDate: Date(timeIntervalSince1970: 3),
            userTitle: nil, title: "three", tags: [], collectionIDs: [b]), ocrText: "")
        let rows = try db.rows(inFolder: "/x")
        let members = collectionMemberRows(rows, collectionID: a).map { ($0.path as NSString).lastPathComponent }
        XCTAssertEqual(Set(members), ["1.seal", "2.seal"])
    }

    func test_favoriteMemberRows_filtersByFavoriteFlag() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let db = try LibraryIndexDB(url: url)
        try db.upsert(CaptureIndexRow(path: "/x/1.seal", folder: "/x",
            mtime: Date(timeIntervalSince1970: 1), captureDate: Date(timeIntervalSince1970: 1),
            userTitle: nil, title: "fav", tags: [], isFavorite: true), ocrText: "")
        try db.upsert(CaptureIndexRow(path: "/x/2.seal", folder: "/x",
            mtime: Date(timeIntervalSince1970: 2), captureDate: Date(timeIntervalSince1970: 2),
            userTitle: nil, title: "plain", tags: [], isFavorite: false), ocrText: "")
        let rows = try db.rows(inFolder: "/x")
        let favs = favoriteMemberRows(rows).map { ($0.path as NSString).lastPathComponent }
        XCTAssertEqual(favs, ["1.seal"])
    }

    /// Old schema without collection_ids — mirrors createOldSchema in
    /// LibraryIndexSortColumnsTests but also omits the newer sort columns to
    /// prove the migration chain works end-to-end.
    private func createOldSchema(at url: URL) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
            CREATE TABLE captures(
              path TEXT PRIMARY KEY, folder TEXT NOT NULL, mtime REAL NOT NULL,
              capture_date REAL NOT NULL, user_title TEXT,
              title TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '');
            CREATE VIRTUAL TABLE captures_fts USING fts5(path UNINDEXED, ocr_text);
            """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }
}
