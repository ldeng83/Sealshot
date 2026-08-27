import XCTest
@testable import Sealshot

final class LibraryIndexDBTests: XCTestCase {

    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryIndexDBTests-\(UUID().uuidString)")
            .appendingPathComponent("index.sqlite")
    }

    private func row(path: String, folder: String = "/shots",
                     mtime: TimeInterval = 100, date: TimeInterval = 200,
                     userTitle: String? = nil, title: String = "",
                     tags: [String] = []) -> CaptureIndexRow {
        CaptureIndexRow(path: path, folder: folder,
                        mtime: Date(timeIntervalSince1970: mtime),
                        captureDate: Date(timeIntervalSince1970: date),
                        userTitle: userTitle, title: title, tags: tags)
    }

    // MARK: core CRUD

    func test_upsertAndRows_roundTrip_newestFirst() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        try db.upsert(row(path: "/shots/a.seal", date: 100,
                          userTitle: "Hello", title: "t", tags: ["x", "y"]),
                      ocrText: "some text")
        try db.upsert(row(path: "/shots/b.seal", date: 300), ocrText: "")

        let rows = try db.rows(inFolder: "/shots")
        XCTAssertEqual(rows.map(\.path), ["/shots/b.seal", "/shots/a.seal"])
        XCTAssertEqual(rows[1].userTitle, "Hello")
        XCTAssertEqual(rows[1].tags, ["x", "y"])
        XCTAssertEqual(rows[1].title, "t")
        XCTAssertNil(rows[0].userTitle)
        XCTAssertEqual(rows[0].tags, [])
    }

    func test_upsert_samePathReplaces() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        try db.upsert(row(path: "/shots/a.seal", mtime: 1, title: "old"), ocrText: "")
        try db.upsert(row(path: "/shots/a.seal", mtime: 2, title: "new"), ocrText: "")

        let rows = try db.rows(inFolder: "/shots")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "new")
        XCTAssertEqual(rows[0].mtime, Date(timeIntervalSince1970: 2))
    }

    func test_rows_scopedToFolder() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        try db.upsert(row(path: "/shots/a.seal", folder: "/shots"), ocrText: "")
        try db.upsert(row(path: "/shots/Deleted/b.seal", folder: "/shots/Deleted"),
                      ocrText: "")
        XCTAssertEqual(try db.rows(inFolder: "/shots").count, 1)
        XCTAssertEqual(try db.rows(inFolder: "/shots/Deleted").count, 1)
    }

    func test_delete_removesRows() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        try db.upsert(row(path: "/shots/a.seal"), ocrText: "abc")
        try db.upsert(row(path: "/shots/b.seal"), ocrText: "")
        try db.delete(paths: ["/shots/a.seal"])
        XCTAssertEqual(try db.rows(inFolder: "/shots").map(\.path), ["/shots/b.seal"])
    }

    func test_persistsAcrossReopen() throws {
        let url = tempDBURL()
        try LibraryIndexDB(url: url).upsert(row(path: "/shots/a.seal"), ocrText: "")
        let reopened = try LibraryIndexDB(url: url)
        XCTAssertEqual(try reopened.rows(inFolder: "/shots").count, 1)
    }

    func test_openRecreatingOnFailure_recoversFromCorruptFile() throws {
        let url = tempDBURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("definitely not a sqlite database file at all".utf8).write(to: url)

        let db = LibraryIndexDB.openRecreatingOnFailure(at: url)
        XCTAssertNotNil(db)
        try db?.upsert(row(path: "/shots/a.seal"), ocrText: "")
        XCTAssertEqual(try db?.rows(inFolder: "/shots").count, 1)
    }

    // MARK: FTS

    func test_ftsQuery_quotesTermsAndAddsPrefixStar() {
        XCTAssertEqual(LibraryIndexDB.ftsQuery(from: "hello world"),
                       "\"hello\"* \"world\"*")
        XCTAssertEqual(LibraryIndexDB.ftsQuery(from: "  spaced   out "),
                       "\"spaced\"* \"out\"*")
        XCTAssertNil(LibraryIndexDB.ftsQuery(from: "   "))
    }

    func test_ftsQuery_neutralizesOperatorsAndQuotes() {
        XCTAssertEqual(LibraryIndexDB.ftsQuery(from: "a AND b"),
                       "\"a\"* \"AND\"* \"b\"*")
        XCTAssertEqual(LibraryIndexDB.ftsQuery(from: "say \"hi\""),
                       "\"say\"* \"\"\"hi\"\"\"*")
    }

    func test_ocrMatches_findsPrefixHits_withSnippet() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        try db.upsert(row(path: "/shots/a.seal"),
                      ocrText: "Invoice number 12345\nTotal due September")
        try db.upsert(row(path: "/shots/b.seal"), ocrText: "nothing relevant")

        let hits = try db.ocrMatches(query: "invoi", inFolder: "/shots")
        XCTAssertEqual(Array(hits.keys), ["/shots/a.seal"])
        // The matched token is wrapped in the hit sentinels so display code
        // can bold it and keep it visible.
        XCTAssertTrue(try XCTUnwrap(hits["/shots/a.seal"]).contains(
            LibraryIndexDB.snippetHitStart + "Invoice" + LibraryIndexDB.snippetHitEnd))
    }

    func test_ocrMatches_diacriticInsensitive() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        try db.upsert(row(path: "/shots/a.seal"), ocrText: "café receipt")
        XCTAssertEqual(try db.ocrMatches(query: "cafe", inFolder: "/shots").count, 1)
    }

    func test_ocrMatches_scopedToFolder() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        try db.upsert(row(path: "/shots/Deleted/a.seal", folder: "/shots/Deleted"),
                      ocrText: "secret word")
        XCTAssertTrue(try db.ocrMatches(query: "secret", inFolder: "/shots").isEmpty)
    }

    func test_ocrMatches_operatorInput_doesNotThrow() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        try db.upsert(row(path: "/shots/a.seal"), ocrText: "plain text")
        XCTAssertNoThrow(try db.ocrMatches(query: "NEAR(", inFolder: "/shots"))
        XCTAssertNoThrow(try db.ocrMatches(query: "a -b \"c", inFolder: "/shots"))
    }

    func test_ocrMatches_staleFTSRowAfterDelete_neverResurfaces() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        try db.upsert(row(path: "/shots/a.seal"), ocrText: "zebra")
        try db.delete(paths: ["/shots/a.seal"])
        XCTAssertTrue(try db.ocrMatches(query: "zebra", inFolder: "/shots").isEmpty)
    }

    // MARK: smartKeywords (Task 5)

    func test_smartKeywords_column_roundTrips() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        let r = CaptureIndexRow(path: "/shots/a.seal", folder: "/shots",
                                mtime: Date(timeIntervalSince1970: 100),
                                captureDate: Date(timeIntervalSince1970: 200),
                                userTitle: nil, title: "t",
                                tags: ["userT"], smartKeywords: ["autoK"])
        try db.upsert(r, ocrText: "")
        let back = try XCTUnwrap(db.rows(inFolder: "/shots").first)
        XCTAssertEqual(back.smartKeywords, ["autoK"])
        XCTAssertEqual(back.tags, ["userT"])
    }

    // MARK: captureKind + durationSeconds (slice 5a)

    func testIndexesCaptureKindAndDuration() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        let videoRow = CaptureIndexRow(
            path: "/x/rec.seal", folder: "/x", mtime: Date(timeIntervalSince1970: 1),
            captureDate: Date(timeIntervalSince1970: 2), userTitle: nil, title: "Rec",
            tags: [], fileSize: 10, category: nil, isFavorite: false, status: .new,
            captureKind: .screenRecording, durationSeconds: 12.5)
        try db.upsert(videoRow, ocrText: "")
        let back = try XCTUnwrap(db.rows(inFolder: "/x").first)
        XCTAssertEqual(back.captureKind, .screenRecording)
        XCTAssertEqual(back.durationSeconds, 12.5, accuracy: 0.001)
    }

    func testIndexesCaptureKind_nilWhenAbsent() throws {
        let db = try LibraryIndexDB(url: tempDBURL())
        // Default row (no captureKind/durationSeconds)
        try db.upsert(row(path: "/shots/img.seal"), ocrText: "")
        let back = try XCTUnwrap(db.rows(inFolder: "/shots").first)
        XCTAssertNil(back.captureKind)
        XCTAssertEqual(back.durationSeconds, 0, accuracy: 0.001)
    }

    // MARK: width/height/sourceApp (Task 1)

    func testRoundTripsDimensionsAndSourceApp() throws {
        let db = try LibraryIndexDB(inMemoryFrom: nil)
        let row = CaptureIndexRow(
            path: "/lib/a.seal", folder: "/lib",
            mtime: Date(timeIntervalSince1970: 100),
            captureDate: Date(timeIntervalSince1970: 100),
            userTitle: nil, title: "A", tags: [],
            width: 2560, height: 1440, sourceApp: "Safari")
        try db.upsert(row, ocrText: "")
        let read = try db.rows(inFolder: "/lib")
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].width, 2560)
        XCTAssertEqual(read[0].height, 1440)
        XCTAssertEqual(read[0].sourceApp, "Safari")
    }

    func testDefaultsWhenOmitted() throws {
        let db = try LibraryIndexDB(inMemoryFrom: nil)
        let row = CaptureIndexRow(
            path: "/lib/b.seal", folder: "/lib",
            mtime: Date(timeIntervalSince1970: 100),
            captureDate: Date(timeIntervalSince1970: 100),
            userTitle: nil, title: "B", tags: [])   // no dims/app
        try db.upsert(row, ocrText: "")
        let read = try db.rows(inFolder: "/lib")
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].width, 0)
        XCTAssertEqual(read[0].height, 0)
        XCTAssertNil(read[0].sourceApp)
    }
}
