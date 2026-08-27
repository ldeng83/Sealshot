import XCTest
import CryptoKit
@testable import Sealshot

@MainActor
final class RecordingsMigratorTests: XCTestCase {
    private var saveFolder: URL!
    private var recordings: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        saveFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recmig-\(UUID().uuidString)", isDirectory: true)
        recordings = RecordingsLibrary.folder(forSaveFolder: saveFolder)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: saveFolder) }

    private func write(_ name: String, _ bytes: Data) throws {
        try bytes.write(to: recordings.appendingPathComponent(name))
    }
    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: recordings.appendingPathComponent(name).path)
    }

    func test_encryptThenDecrypt_roundTripsAndSwapsExtensions() async throws {
        // Dummy video bytes — the thumbnail step yields nil (not real video),
        // which is fine; the migrator just encrypts the file content.
        let movBytes = Data((0..<5000).map { UInt8($0 % 251) })
        try write("clip.mov", movBytes)

        await RecordingsMigrator.encryptAll(in: saveFolder, key: key)
        XCTAssertFalse(exists("clip.mov"), "plaintext removed after encrypting")
        XCTAssertTrue(exists("clip.sealrec"), "encrypted container written")

        await RecordingsMigrator.decryptAll(in: saveFolder, key: key)
        XCTAssertFalse(exists("clip.sealrec"), "container removed after decrypting")
        XCTAssertTrue(exists("clip.mov"), "plaintext restored")
        XCTAssertEqual(try Data(contentsOf: recordings.appendingPathComponent("clip.mov")), movBytes)
    }

    func test_encrypt_isNoOpWithNoPlaintext() async throws {
        await RecordingsMigrator.encryptAll(in: saveFolder, key: key)
        XCTAssertEqual(RecordingsLibrary.items(in: recordings).count, 0)
    }

    func test_mp4_restoresWithMp4Extension() async throws {
        try write("rec.mp4", Data((0..<1200).map { UInt8($0 % 251) }))
        await RecordingsMigrator.encryptAll(in: saveFolder, key: key)
        XCTAssertTrue(exists("rec.sealrec"))
        await RecordingsMigrator.decryptAll(in: saveFolder, key: key)
        XCTAssertTrue(exists("rec.mp4"), "original .mp4 extension restored from header UTI")
    }
}
