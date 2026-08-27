import XCTest
import CryptoKit
@testable import Sealshot

/// A locked app must never read the plaintext search index.
///
/// The index holds OCR text, titles and tags. It is plaintext by design while
/// encryption is OFF, and is replaced by a sealed blob once encryption is on —
/// but `EncryptedIndexFile.persist` only deletes the plaintext file *after* a
/// successful sealed write. A crash or force-quit between enabling encryption
/// and that first persist left the plaintext file on disk. `database()` then
/// saw a nil key (locked) and fell through to the same branch used by
/// encryption-off users, opening it and serving real search hits on a locked
/// app.
///
/// The nil key was ambiguous: it means "no encryption" for one user and
/// "locked" for another. These tests pin the two apart.
@MainActor
final class LockedIndexPlaintextTests: XCTestCase {

    private var dir: URL!
    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LockedIndex-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("libraryIndex.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Writes a plaintext index carrying OCR text, exactly as one left behind
    /// by an interrupted migration would look.
    private func writeStalePlaintextIndex() throws {
        let db = try LibraryIndexDB(url: dbURL)
        try db.upsert(CaptureIndexRow(path: "/tmp/secret.seal", folder: "/tmp",
                                      mtime: Date(timeIntervalSince1970: 100),
                                      captureDate: Date(timeIntervalSince1970: 90),
                                      userTitle: nil, title: "Bank statement",
                                      tags: ["finance"]),
                      ocrText: "ACCOUNT 12345678 SORTCODE")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
    }

    func test_lockedStoreDoesNotServeHitsFromAStalePlaintextIndex() async throws {
        try writeStalePlaintextIndex()

        // Encryption ON, session locked: no key available.
        let store = LibraryIndexStore(databaseURL: dbURL,
                                      keyProvider: { nil },
                                      encryptionEnabled: { true })

        let tags = await store.allTags()
        XCTAssertTrue(tags.isEmpty,
                      "a locked app must not read tags out of the plaintext index")
    }

    /// The counterpart: encryption genuinely off is the normal plaintext mode
    /// and must keep working. Without this, "fix the leak" could just as well
    /// mean "break search for every non-encrypting user".
    func test_encryptionOffStillReadsThePlaintextIndex() async throws {
        try writeStalePlaintextIndex()

        let store = LibraryIndexStore(databaseURL: dbURL,
                                      keyProvider: { nil },
                                      encryptionEnabled: { false })

        let tags = await store.allTags()
        XCTAssertEqual(tags.map(\.tag), ["finance"],
                       "with encryption off the plaintext index is the normal mode")
    }

    /// Belt to the brace: switching encryption on removes the file outright,
    /// so the refusal above is the second line of defence rather than the only
    /// one. The file is what's exposed — it sits unencrypted in Application
    /// Support where anything can read it, app or not.
    func test_purgeRemovesThePlaintextIndexFile() throws {
        try writeStalePlaintextIndex()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        LibraryIndexStore.purgePlaintextIndex(at: dbURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path),
                       "enabling encryption must not leave a plaintext index behind")
    }

    func test_purgeIsSafeWhenNoPlaintextIndexExists() {
        let absent = dir.appendingPathComponent("nope.sqlite")
        LibraryIndexStore.purgePlaintextIndex(at: absent)   // must not throw
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }
}
