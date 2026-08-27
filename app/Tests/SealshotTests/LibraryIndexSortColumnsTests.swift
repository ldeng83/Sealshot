import XCTest
import SQLite3
@testable import Sealshot

/// The capture index persists file size + category (added for Library sorting)
/// and migrates pre-existing databases that lack the columns.
final class LibraryIndexSortColumnsTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID().uuidString).sqlite")
    }

    private func row(_ path: String, size: Int64, category: ScreenshotCategory?) -> CaptureIndexRow {
        CaptureIndexRow(path: path, folder: "/lib", mtime: Date(timeIntervalSince1970: 1),
                        captureDate: Date(timeIntervalSince1970: 2), userTitle: nil,
                        title: "T", tags: [], fileSize: size, category: category)
    }

    func test_upsertAndRead_roundTripsSizeAndCategory() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let db = try LibraryIndexDB(url: url)
        try db.upsert(row("/lib/a.seal", size: 4242, category: .code), ocrText: "")
        let read = try db.rows(inFolder: "/lib")
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.fileSize, 4242)
        XCTAssertEqual(read.first?.category, .code)
    }

    func test_nilCategory_roundTripsAsNil() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let db = try LibraryIndexDB(url: url)
        try db.upsert(row("/lib/b.seal", size: 10, category: nil), ocrText: "")
        XCTAssertNil(try db.rows(inFolder: "/lib").first?.category)
    }

    /// A database created by the OLD schema (no size/category columns) must be
    /// migrated transparently on open, then read back fine.
    func test_oldSchemaDatabase_migratesAndReads() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        createOldSchema(at: url)   // a DB with the pre-sort `captures` columns
        // Opening through the real type must migrate (add the columns) without
        // error, and reads/writes must then carry size + category.
        let db = try LibraryIndexDB(url: url)
        try db.upsert(row("/lib/c.seal", size: 7, category: .error), ocrText: "")
        let read = try db.rows(inFolder: "/lib")
        XCTAssertEqual(read.first?.fileSize, 7)
        XCTAssertEqual(read.first?.category, .error)
    }

    /// The original `captures` schema (no file_size / category), built directly
    /// so we can prove the migration upgrades a legacy database in place.
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
