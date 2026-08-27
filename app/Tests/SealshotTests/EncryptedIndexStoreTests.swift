import XCTest
import CryptoKit
@testable import Sealshot

final class EncryptedIndexStoreTests: XCTestCase {
    var dir: URL!
    let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("encidx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testSealedFileRoundTrip() throws {
        let url = dir.appendingPathComponent("libraryIndex.sqlite")
        let file = EncryptedIndexFile(databaseURL: url)
        let db1 = try LibraryIndexDB(inMemoryFrom: nil)
        try db1.upsert(CaptureIndexRow(path: "/tmp/x.seal", folder: "/tmp",
                                       mtime: Date(), captureDate: Date(),
                                       userTitle: nil, title: "hello", tags: []),
                       ocrText: "PASSWORD=hunter2")
        try file.persist(db1, key: key)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let raw = try Data(contentsOf: file.sealedURL)
        XCTAssertTrue(SealedBlob.isSealed(raw))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("hunter2"))

        let db2 = try XCTUnwrap(EncryptedIndexFile(databaseURL: url).load(key: key))
        XCTAssertEqual(try db2.rows(inFolder: "/tmp").count, 1)
    }

    func testLoadMissingReturnsEmptyDB() throws {
        let file = EncryptedIndexFile(databaseURL: dir.appendingPathComponent("idx.sqlite"))
        let db = try XCTUnwrap(file.load(key: key))
        XCTAssertEqual(try db.rows(inFolder: "/none"), [])
    }

    func testLoadWrongKeyReturnsFreshEmptyDB() throws {
        let url = dir.appendingPathComponent("idx.sqlite")
        let file = EncryptedIndexFile(databaseURL: url)
        let db = try XCTUnwrap(file.load(key: key))
        try file.persist(db, key: key)
        let other = try XCTUnwrap(file.load(key: SymmetricKey(size: .bits256)))
        XCTAssertEqual(try other.rows(inFolder: "/none"), [])
    }
}
