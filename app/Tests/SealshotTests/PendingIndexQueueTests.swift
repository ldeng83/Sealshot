import XCTest
@testable import Sealshot

final class PendingIndexQueueTests: XCTestCase {
    var dir: URL!
    var identity: IdentityKey!
    var gen: KeyGeneration!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        identity = IdentityKey.generate()
        gen = KeyGeneration.make(publicKey: identity.publicKey)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func entry(_ path: String) -> PendingIndexEntry {
        PendingIndexEntry(
            row: CaptureIndexRow(path: path, folder: "/tmp", mtime: Date(timeIntervalSince1970: 5),
                                 captureDate: Date(timeIntervalSince1970: 4),
                                 userTitle: nil, title: "t", tags: []),
            ocrText: "secret text")
    }

    func testAppendNeedsOnlyPublicKey() throws {
        let q = PendingIndexQueue(folder: dir)
        try q.append(entry("/tmp/a.seal"), publicKey: identity.publicKey, generation: gen)
        XCTAssertEqual(q.count, 1)
    }

    func testEntriesAreEncryptedOnDisk() throws {
        let q = PendingIndexQueue(folder: dir)
        try q.append(entry("/tmp/a.seal"), publicKey: identity.publicKey, generation: gen)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let raw = try Data(contentsOf: files.first { $0.pathExtension == "pending" }!)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("secret text"))
    }

    func testDrainDecryptsAndEmpties() throws {
        let q = PendingIndexQueue(folder: dir)
        try q.append(entry("/tmp/a.seal"), publicKey: identity.publicKey, generation: gen)
        try q.append(entry("/tmp/b.seal"), publicKey: identity.publicKey, generation: gen)
        let drained = q.drain(identity: identity)
        XCTAssertEqual(Set(drained.map(\.row.path)), ["/tmp/a.seal", "/tmp/b.seal"])
        XCTAssertEqual(q.count, 0)
    }

    func testDrainSkipsCorruptEntries() throws {
        let q = PendingIndexQueue(folder: dir)
        try q.append(entry("/tmp/a.seal"), publicKey: identity.publicKey, generation: gen)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("zz.pending"))
        XCTAssertEqual(q.drain(identity: identity).count, 1)
        XCTAssertEqual(q.count, 0)
    }
}
