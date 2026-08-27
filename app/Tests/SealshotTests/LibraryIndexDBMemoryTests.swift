import XCTest
@testable import Sealshot

final class LibraryIndexDBMemoryTests: XCTestCase {
    private func sampleRow(path: String) -> CaptureIndexRow {
        CaptureIndexRow(path: path, folder: "/tmp/captures", mtime: Date(timeIntervalSince1970: 1000),
                        captureDate: Date(timeIntervalSince1970: 900),
                        userTitle: nil, title: "Login Page", tags: ["error"])
    }

    func testInMemoryFromNilStartsEmpty() throws {
        let db = try LibraryIndexDB(inMemoryFrom: nil)
        XCTAssertEqual(try db.rows(inFolder: "/tmp/captures"), [])
    }

    func testSerializeDeserializeRoundTrip() throws {
        let db1 = try LibraryIndexDB(inMemoryFrom: nil)
        try db1.upsert(sampleRow(path: "/tmp/captures/a.seal"), ocrText: "API_KEY=sk-12345")
        let bytes = try db1.serialize()

        let db2 = try LibraryIndexDB(inMemoryFrom: bytes)
        XCTAssertEqual(try db2.rows(inFolder: "/tmp/captures").count, 1)
        let hits = try db2.ocrMatches(query: "API_KEY", inFolder: "/tmp/captures")
        XCTAssertEqual(hits.count, 1)
    }

    func testDeserializeGarbageThrows() {
        XCTAssertThrowsError(try LibraryIndexDB(inMemoryFrom: Data("garbage".utf8)))
    }
}
