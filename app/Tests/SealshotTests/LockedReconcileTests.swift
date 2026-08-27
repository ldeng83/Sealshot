import XCTest
import CryptoKit
@testable import Sealshot

final class LockedReconcileTests: XCTestCase {
    func testUpdateMtimePreservesRowAndFTS() throws {
        let db = try LibraryIndexDB(inMemoryFrom: nil)
        let row = CaptureIndexRow(path: "/tmp/a.seal", folder: "/tmp",
                                  mtime: Date(timeIntervalSince1970: 100),
                                  captureDate: Date(timeIntervalSince1970: 90),
                                  userTitle: nil, title: "Drained Title", tags: ["t"])
        try db.upsert(row, ocrText: "SECRET ocr")
        try db.updateMtime(path: "/tmp/a.seal", mtime: Date(timeIntervalSince1970: 200))
        let rows = try db.rows(inFolder: "/tmp")
        XCTAssertEqual(rows.first?.title, "Drained Title")
        XCTAssertEqual(rows.first?.mtime, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try db.ocrMatches(query: "SECRET", inFolder: "/tmp").count, 1)
    }
}
