import XCTest
@testable import Sealshot

final class LibraryIndexAllTagsTests: XCTestCase {

    private func row(_ path: String, _ tags: [String]) -> CaptureIndexRow {
        CaptureIndexRow(path: path, folder: "/lib", mtime: Date(),
                        captureDate: Date(), userTitle: nil, title: "t", tags: tags)
    }

    func testAggregatesAndCountsTagsAcrossCaptures() throws {
        let db = try LibraryIndexDB(inMemoryFrom: nil)
        try db.upsert(row("/a.seal", ["bug", "code"]), ocrText: "")
        try db.upsert(row("/b.seal", ["bug", "design"]), ocrText: "")
        try db.upsert(row("/c.seal", ["bug"]), ocrText: "")

        let result = try db.allTags()

        XCTAssertEqual(result.first?.tag, "bug")
        XCTAssertEqual(result.first?.count, 3)
        XCTAssertEqual(Set(result.map(\.tag)), ["bug", "code", "design"])
    }

    func testSortsByCountThenAlphabetically() throws {
        let db = try LibraryIndexDB(inMemoryFrom: nil)
        try db.upsert(row("/a.seal", ["zebra", "apple"]), ocrText: "")
        try db.upsert(row("/b.seal", ["apple"]), ocrText: "")

        let result = try db.allTags()

        XCTAssertEqual(result.map(\.tag), ["apple", "zebra"])
    }

    func testEmptyDatabaseReturnsNoTags() throws {
        let db = try LibraryIndexDB(inMemoryFrom: nil)
        XCTAssertTrue(try db.allTags().isEmpty)
    }
}
