import Foundation
import SQLite3
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "library-index")

/// `sqlite3_bind_text` destructor telling SQLite to copy the buffer.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One capture's indexed metadata — everything the Library needs to list,
/// sort and direct-match search. OCR text lives only in the FTS table.
struct CaptureIndexRow: Equatable, Codable {
    /// Standardized file path; primary key.
    let path: String
    /// Standardized parent folder path; rows are queried per folder so the
    /// Trash never leaks into All Shots.
    let folder: String
    /// File mtime when the manifest was read — the reconcile freshness key.
    let mtime: Date
    let captureDate: Date
    let userTitle: String?
    let title: String
    let tags: [String]
    /// Auto-generated keywords from AI analysis. Searched alongside `tags` but
    /// excluded from the user-facing tag vocabulary (autocomplete uses `tags` only).
    let smartKeywords: [String]
    /// `.seal` package size on disk in bytes (0 = unknown). Library sort key.
    let fileSize: Int64
    /// Capture category, nil when none. Library sort key.
    let category: ScreenshotCategory?
    /// User Favorite flag. Library filter key.
    let isFavorite: Bool
    /// Triage status. Library filter key.
    let status: CaptureStatus
    /// How this capture originated (.screenRecording for video .seals). nil = unknown/legacy.
    let captureKind: CaptureKind?
    /// Playback duration in seconds (0 for images / unknown). Library display key.
    let durationSeconds: Double
    /// Collection membership: UUIDs of `CaptureCollection`s this capture belongs to.
    /// Mirrored from `SealManifest.collectionIDs` on every reconcile.
    let collectionIDs: [UUID]
    /// v-dims: pixel width of the immutable source (0 = unknown, the backfill
    /// sentinel for `.seal` rows). Library display + `.dimensions` sort key.
    let width: Int
    /// v-dims: pixel height (0 = unknown).
    let height: Int
    /// v-dims: capturing application name; nil when unknown (videos/legacy).
    /// Library display + `.sourceApp` sort key.
    let sourceApp: String?

    init(path: String, folder: String, mtime: Date, captureDate: Date,
         userTitle: String?, title: String, tags: [String],
         smartKeywords: [String] = [],
         fileSize: Int64 = 0, category: ScreenshotCategory? = nil,
         isFavorite: Bool = false, status: CaptureStatus = .new,
         captureKind: CaptureKind? = nil, durationSeconds: Double = 0,
         collectionIDs: [UUID] = [],
         width: Int = 0, height: Int = 0, sourceApp: String? = nil) {
        self.path = path
        self.folder = folder
        self.mtime = mtime
        self.captureDate = captureDate
        self.userTitle = userTitle
        self.title = title
        self.tags = tags
        self.smartKeywords = smartKeywords
        self.fileSize = fileSize
        self.category = category
        self.isFavorite = isFavorite
        self.status = status
        self.captureKind = captureKind
        self.durationSeconds = durationSeconds
        self.collectionIDs = collectionIDs
        self.width = width
        self.height = height
        self.sourceApp = sourceApp
    }

    /// Custom decode so pending-queue entries written before `fileSize`/
    /// `category`/`isFavorite`/`status` existed still decode (defaulting to
    /// 0 / nil / false / .new). Encode stays synthesized, so new entries
    /// always carry all fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        folder = try c.decode(String.self, forKey: .folder)
        mtime = try c.decode(Date.self, forKey: .mtime)
        captureDate = try c.decode(Date.self, forKey: .captureDate)
        userTitle = try c.decodeIfPresent(String.self, forKey: .userTitle)
        title = try c.decode(String.self, forKey: .title)
        tags = try c.decode([String].self, forKey: .tags)
        smartKeywords = try c.decodeIfPresent([String].self, forKey: .smartKeywords) ?? []
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        category = try c.decodeIfPresent(ScreenshotCategory.self, forKey: .category)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        status = try c.decodeIfPresent(CaptureStatus.self, forKey: .status) ?? .new
        captureKind = try c.decodeIfPresent(CaptureKind.self, forKey: .captureKind)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        collectionIDs = try c.decodeIfPresent([UUID].self, forKey: .collectionIDs) ?? []
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
    }
}

/// Single-connection SQLite wrapper for the Library's capture index. NOT
/// thread-safe on its own — `LibraryIndexStore` (an actor) serializes all
/// access. The database is a disposable cache: the `.seal` packages remain
/// the source of truth, so corruption costs a rebuild, never data.
final class LibraryIndexDB {

    enum DBError: Error { case open(Int32), exec(String), prepare(String) }

    private let db: OpaquePointer

    /// The SQLite `user_version` this build writes — bumped each time a schema
    /// or data migration needs every existing row to be re-reconciled from disk.
    static let schemaVersion: Int32 = 4

    /// True when the DB was opened and its `user_version` was below
    /// `schemaVersion`, meaning it predates the smart-keywords backfill.
    /// `LibraryIndexStore.reconcile` skips the mtime fast-path while this is
    /// true so every manifest is re-read and re-upserted this launch, allowing
    /// the per-manifest `CaptureMetadata` decode migration to move old combined
    /// tags into `smartKeywords` and leave user `tags` empty.
    /// Persisted `user_version` prevents re-flagging on subsequent launches.
    private(set) var needsSmartKeywordsRemigration = false

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw DBError.open(rc)
        }
        self.db = handle
        do { try createSchema() } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    /// In-memory database for encrypted-at-rest operation: contents are
    /// loaded from / saved to an encrypted file by the caller, so SQLite
    /// itself never touches disk. `data` nil starts an empty index.
    init(inMemoryFrom data: Data?) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(":memory:", &handle,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw DBError.open(rc)
        }
        self.db = handle
        if let data, !data.isEmpty {
            // sqlite takes ownership of a malloc'd copy (FREEONCLOSE).
            guard let buf = sqlite3_malloc64(sqlite3_uint64(data.count)) else {
                sqlite3_close(handle); throw DBError.open(SQLITE_NOMEM)
            }
            data.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
            let drc = sqlite3_deserialize(
                handle, "main",
                buf.assumingMemoryBound(to: UInt8.self),
                sqlite3_int64(data.count), sqlite3_int64(data.count),
                UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE))
            // No sqlite3_free(buf) here: with FREEONCLOSE, sqlite frees the
            // buffer itself when deserialize fails ("sqlite3_free() is
            // invoked on argument P prior to returning" — sqlite3.h). Adding
            // a free here would be a double-free.
            guard drc == SQLITE_OK else { sqlite3_close(handle); throw DBError.open(drc) }
            // Garbage "deserializes" fine but fails on first statement —
            // validate it is actually a database now.
            do { try validateDeserialized() } catch { sqlite3_close(handle); throw error }
        }
        do { try createSchema() } catch { sqlite3_close(handle); throw error }
    }

    /// First real statement against a deserialized image — throws on garbage.
    private func validateDeserialized() throws {
        let stmt = try prepare("SELECT count(*) FROM sqlite_master")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DBError.exec(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Snapshot the whole database as bytes (caller encrypts + persists).
    func serialize() throws -> Data {
        var size: sqlite3_int64 = 0
        guard let bytes = sqlite3_serialize(db, "main", &size, 0) else {
            throw DBError.exec("sqlite3_serialize returned NULL")
        }
        defer { sqlite3_free(bytes) }
        return Data(bytes: bytes, count: Int(size))
    }

    deinit { sqlite3_close(db) }

    /// Open the DB, deleting and recreating the file on failure — the index
    /// is a disposable cache; a corrupt file costs a rebuild, not data.
    static func openRecreatingOnFailure(at url: URL) -> LibraryIndexDB? {
        if let db = try? LibraryIndexDB(url: url) { return db }
        os_log("library index unreadable, recreating: %{public}@",
               log: log, type: .error, url.path)
        try? FileManager.default.removeItem(at: url)
        return try? LibraryIndexDB(url: url)
    }

    // MARK: writes

    func upsert(_ row: CaptureIndexRow, ocrText: String) throws {
        try exec("SAVEPOINT upsert_row")
        do {
            let stmt = try prepare("""
                INSERT INTO captures(path, folder, mtime, capture_date, user_title, title, tags, file_size, category, is_favorite, status, capture_kind, duration_seconds, collection_ids, smart_keywords, width, height, source_app)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET
                  folder=excluded.folder, mtime=excluded.mtime,
                  capture_date=excluded.capture_date, user_title=excluded.user_title,
                  title=excluded.title, tags=excluded.tags,
                  file_size=excluded.file_size, category=excluded.category,
                  is_favorite=excluded.is_favorite, status=excluded.status,
                  capture_kind=excluded.capture_kind, duration_seconds=excluded.duration_seconds,
                  collection_ids=excluded.collection_ids,
                  smart_keywords=excluded.smart_keywords,
                  width=excluded.width, height=excluded.height,
                  source_app=excluded.source_app
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, row.path)
            bind(stmt, 2, row.folder)
            sqlite3_bind_double(stmt, 3, row.mtime.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, row.captureDate.timeIntervalSince1970)
            bind(stmt, 5, row.userTitle)
            bind(stmt, 6, row.title)
            bind(stmt, 7, row.tags.joined(separator: "\n"))
            sqlite3_bind_int64(stmt, 8, row.fileSize)
            bind(stmt, 9, row.category?.rawValue ?? "")
            sqlite3_bind_int(stmt, 10, row.isFavorite ? 1 : 0)
            bind(stmt, 11, row.status.rawValue)
            bind(stmt, 12, row.captureKind?.rawValue ?? "")
            sqlite3_bind_double(stmt, 13, row.durationSeconds)
            bind(stmt, 14, row.collectionIDs.map { $0.uuidString }.joined(separator: "\n"))
            bind(stmt, 15, row.smartKeywords.joined(separator: "\n"))
            sqlite3_bind_int(stmt, 16, Int32(row.width))
            sqlite3_bind_int(stmt, 17, Int32(row.height))
            bind(stmt, 18, row.sourceApp ?? "")
            try stepDone(stmt)

            let del = try prepare("DELETE FROM captures_fts WHERE path = ?")
            defer { sqlite3_finalize(del) }
            bind(del, 1, row.path)
            try stepDone(del)

            let ins = try prepare("INSERT INTO captures_fts(path, ocr_text) VALUES(?,?)")
            defer { sqlite3_finalize(ins) }
            bind(ins, 1, row.path)
            bind(ins, 2, ocrText)
            try stepDone(ins)

            try exec("RELEASE upsert_row")
        } catch {
            try? exec("ROLLBACK TO upsert_row")
            try? exec("RELEASE upsert_row")
            throw error
        }
    }

    /// Update only the mtime for an existing row, leaving title/tags/FTS intact.
    /// Used by reconcile for locked packages that were already indexed via
    /// pending-queue drain — a full upsert here would clobber their rich metadata
    /// with empty title/tags.
    func updateMtime(path: String, mtime: Date) throws {
        let stmt = try prepare("UPDATE captures SET mtime=? WHERE path=?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, mtime.timeIntervalSince1970)
        bind(stmt, 2, path)
        try stepDone(stmt)
    }

    /// Correct only the sort date for an existing row (leaves title/tags/FTS
    /// untouched) — used by the one-time repair that restores stable manifest
    /// capture dates over filesystem dates wrongly stamped by earlier reconciles.
    func updateCaptureDate(path: String, captureDate: Date) throws {
        let stmt = try prepare("UPDATE captures SET capture_date=? WHERE path=?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, captureDate.timeIntervalSince1970)
        bind(stmt, 2, path)
        try stepDone(stmt)
    }

    func delete(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let del = try prepare("DELETE FROM captures WHERE path = ?")
        let fts = try prepare("DELETE FROM captures_fts WHERE path = ?")
        defer { sqlite3_finalize(del); sqlite3_finalize(fts) }
        for path in paths {
            sqlite3_reset(del); sqlite3_clear_bindings(del)
            bind(del, 1, path)
            try stepDone(del)
            sqlite3_reset(fts); sqlite3_clear_bindings(fts)
            bind(fts, 1, path)
            try stepDone(fts)
        }
    }

    // MARK: reads

    /// All rows directly inside `folder`, newest capture first.
    func rows(inFolder folder: String) throws -> [CaptureIndexRow] {
        let stmt = try prepare("""
            SELECT path, folder, mtime, capture_date, user_title, title, tags, file_size, category, is_favorite, status, capture_kind, duration_seconds, collection_ids, smart_keywords, width, height, source_app
            FROM captures WHERE folder = ? ORDER BY capture_date DESC
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, folder)
        var out: [CaptureIndexRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tags = column(stmt, 6) ?? ""
            let categoryRaw = column(stmt, 8) ?? ""
            // col 9 = is_favorite (INTEGER), col 10 = status (TEXT)
            // col 11 = capture_kind (TEXT), col 12 = duration_seconds (REAL)
            // col 13 = collection_ids (TEXT, newline-joined UUID strings)
            // col 14 = smart_keywords (TEXT, newline-joined)
            // col 15 = width (INTEGER), col 16 = height (INTEGER), col 17 = source_app (TEXT)
            let collectionIDsRaw = column(stmt, 13) ?? ""
            let collectionIDs: [UUID] = collectionIDsRaw.isEmpty ? [] :
                collectionIDsRaw.components(separatedBy: "\n")
                    .compactMap { UUID(uuidString: $0) }
            let smartKeywordsRaw = column(stmt, 14) ?? ""
            let sourceAppRaw = column(stmt, 17) ?? ""
            out.append(CaptureIndexRow(
                path: column(stmt, 0) ?? "",
                folder: column(stmt, 1) ?? "",
                mtime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                captureDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                userTitle: column(stmt, 4),
                title: column(stmt, 5) ?? "",
                tags: tags.isEmpty ? [] : tags.components(separatedBy: "\n"),
                smartKeywords: smartKeywordsRaw.isEmpty ? [] : smartKeywordsRaw.components(separatedBy: "\n"),
                fileSize: sqlite3_column_int64(stmt, 7),
                category: categoryRaw.isEmpty ? nil : ScreenshotCategory(rawValue: categoryRaw),
                isFavorite: sqlite3_column_int(stmt, 9) != 0,
                status: CaptureStatus(rawValue: column(stmt, 10) ?? "new") ?? .new,
                captureKind: { let r = column(stmt, 11) ?? ""; return r.isEmpty ? nil : CaptureKind(rawValue: r) }(),
                durationSeconds: sqlite3_column_double(stmt, 12),
                collectionIDs: collectionIDs,
                width: Int(sqlite3_column_int(stmt, 15)),
                height: Int(sqlite3_column_int(stmt, 16)),
                sourceApp: sourceAppRaw.isEmpty ? nil : sourceAppRaw))
        }
        return out
    }

    /// Every tag in use across all captures, with usage count.
    /// Sorted by count (desc) then tag (asc). Drives the live tag vocabulary.
    func allTags() throws -> [(tag: String, count: Int)] {
        let stmt = try prepare("SELECT tags FROM captures")
        defer { sqlite3_finalize(stmt) }
        var counts: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let raw = column(stmt, 0) ?? ""
            guard !raw.isEmpty else { continue }
            for tag in raw.components(separatedBy: "\n") where !tag.isEmpty {
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    // MARK: FTS

    /// Sentinels wrapped around each FTS hit in `ocrMatches` snippets so
    /// display code can locate and bold the matched terms (see
    /// `searchSnippetDisplay`). Control characters never occur in OCR text.
    static let snippetHitStart = "\u{01}"
    static let snippetHitEnd = "\u{02}"

    /// FTS5 MATCH expression for a user query: each whitespace-separated term
    /// becomes a quoted prefix token (`"foo"*`), implicitly AND-ed. Quoting
    /// stops FTS5 from parsing operators (AND/OR/NEAR/-) or punctuation out
    /// of user input; embedded double quotes are doubled per FTS5 escaping.
    /// Nil when the query has no terms.
    static func ftsQuery(from search: String) -> String? {
        let terms = search.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return nil }
        return terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }

    /// Captures in `folder` whose OCR text matches `search` (token-prefix
    /// match, case/diacritic-insensitive), with a short excerpt around the
    /// first hit — the Library card's "why did this match" line. Keyed by path.
    func ocrMatches(query search: String, inFolder folder: String) throws -> [String: String] {
        guard let match = Self.ftsQuery(from: search) else { return [:] }
        return try ocrMatches(ftsMatch: match, inFolder: folder)
    }

    /// As `ocrMatches(query:)` but takes a pre-built FTS5 MATCH expression —
    /// e.g. the OR query produced by AI search expansion.
    func ocrMatches(ftsMatch match: String, inFolder folder: String) throws -> [String: String] {
        let stmt = try prepare("""
            SELECT f.path, snippet(captures_fts, 1, ?, ?, '…', 10)
            FROM captures_fts f JOIN captures c ON c.path = f.path
            WHERE captures_fts MATCH ? AND c.folder = ?
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Self.snippetHitStart)
        bind(stmt, 2, Self.snippetHitEnd)
        bind(stmt, 3, match)
        bind(stmt, 4, folder)
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let path = column(stmt, 0), let snip = column(stmt, 1) else { continue }
            out[path] = snip
        }
        return out
    }

    // MARK: plumbing

    private func createSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS captures(
              path TEXT PRIMARY KEY,
              folder TEXT NOT NULL,
              mtime REAL NOT NULL,
              capture_date REAL NOT NULL,
              user_title TEXT,
              title TEXT NOT NULL DEFAULT '',
              tags TEXT NOT NULL DEFAULT '',
              file_size INTEGER NOT NULL DEFAULT 0,
              category TEXT NOT NULL DEFAULT '',
              is_favorite INTEGER NOT NULL DEFAULT 0,
              status TEXT NOT NULL DEFAULT 'new',
              capture_kind TEXT NOT NULL DEFAULT '',
              duration_seconds REAL NOT NULL DEFAULT 0,
              collection_ids TEXT NOT NULL DEFAULT '',
              smart_keywords TEXT NOT NULL DEFAULT '',
              width INTEGER NOT NULL DEFAULT 0,
              height INTEGER NOT NULL DEFAULT 0,
              source_app TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS captures_folder_date
              ON captures(folder, capture_date DESC);
            CREATE VIRTUAL TABLE IF NOT EXISTS captures_fts USING fts5(
              path UNINDEXED, ocr_text,
              tokenize='unicode61 remove_diacritics 2');
            """)
        // Migrate databases created before the Library-sort columns existed.
        // ALTER throws "duplicate column name" once present — idempotent, so
        // the failure is ignored.
        addColumnIfMissing("file_size", "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("category", "TEXT NOT NULL DEFAULT ''")
        addColumnIfMissing("is_favorite", "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("status", "TEXT NOT NULL DEFAULT 'new'")
        addColumnIfMissing("capture_kind", "TEXT NOT NULL DEFAULT ''")
        addColumnIfMissing("duration_seconds", "REAL NOT NULL DEFAULT 0")
        addColumnIfMissing("collection_ids", "TEXT NOT NULL DEFAULT ''")
        addColumnIfMissing("smart_keywords", "TEXT NOT NULL DEFAULT ''")
        addColumnIfMissing("width", "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("height", "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing("source_app", "TEXT NOT NULL DEFAULT ''")

        // Version-gated migration: if this DB's user_version is below
        // schemaVersion it predates the tags/smartKeywords split and may
        // have auto-generated keywords stranded in the `tags` index column.
        // Flag it for a forced full re-reconcile this launch, then stamp
        // the new version so the next launch skips it.
        let oldVersion = readUserVersion()
        // A database created just now — first run, after enabling encryption
        // (which mints an empty sealed index), or after corruption recovery —
        // reads as version 0 and so looks like a pre-v4 upgrade. It isn't:
        // an empty index has no stranded auto-tags to migrate. Flagging it
        // condemned the whole session to re-reading every manifest on every
        // reconcile, because the flag gates the fast path and is never
        // cleared. Stamp the version and skip the migration.
        if oldVersion < Self.schemaVersion, isEmptyIndex() {
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
        } else if oldVersion < Self.schemaVersion {
            needsSmartKeywordsRemigration = true
            // Fix the stale INDEX directly, WITHOUT re-reading manifests: at
            // reconcile time these encrypted `.seal` manifests are usually
            // unreadable (crypto identity not yet available → packageLocked), so
            // re-reading to re-normalize never happens. Mirror the split's move
            // in SQL — auto keywords stranded in `tags` (with no smart_keywords)
            // go to smart_keywords, leaving user `tags` empty. Rows that already
            // have smart_keywords (properly split) keep their user `tags`.
            try? exec("UPDATE captures SET smart_keywords = tags, tags = '' WHERE smart_keywords = '' AND tags != ''")
            // Also zero file_size so a later reconcile (once the manifest IS
            // readable) re-reads through the read-time normalization and keeps it durable.
            try? exec("UPDATE captures SET file_size = 0")
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    /// True when `captures` holds no rows — i.e. this database was just
    /// created rather than carrying pre-v4 data. Used to tell "fresh index"
    /// apart from "genuine upgrade", which `user_version == 0` alone cannot.
    private func isEmptyIndex() -> Bool {
        guard let stmt = try? prepare("SELECT EXISTS(SELECT 1 FROM captures)") else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) == 0
    }

    private func addColumnIfMissing(_ name: String, _ declaration: String) {
        try? exec("ALTER TABLE captures ADD COLUMN \(name) \(declaration)")
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.exec(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, sqliteTransient) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func column(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.exec(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// The current SQLite `user_version`. Exposed for unit tests.
    var userVersion: Int32 { readUserVersion() }

    /// Wind `user_version` back. Test-only: the only way to build a database
    /// that looks like a genuine pre-v4 upgrade rather than a fresh one.
    func setUserVersionForTesting(_ version: Int32) {
        try? exec("PRAGMA user_version = \(version)")
    }

    private func readUserVersion() -> Int32 {
        guard let stmt = try? prepare("PRAGMA user_version") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }
}
