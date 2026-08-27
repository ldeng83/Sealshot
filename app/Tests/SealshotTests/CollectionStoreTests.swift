import XCTest
import CryptoKit
@testable import Sealshot

final class CollectionStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("collections-\(UUID().uuidString).sealed")
    }
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("collections-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private let key = SymmetricKey(size: .bits256)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_create_appends_and_persists_across_reload() async throws {
        let url = tempURL()
        let store = CollectionStore(fileURL: url, key: key)
        let a = try await store.create(name: "Invoices", now: t0)
        let b = try await store.create(name: "Trips", now: t0)
        XCTAssertEqual(b.sortIndex, a.sortIndex + 1)
        // Reload from disk: a fresh store sees both, in order.
        let reloaded = CollectionStore(fileURL: url, key: key)
        let all = await reloaded.all()
        XCTAssertEqual(all.map(\.name), ["Invoices", "Trips"])
        try? FileManager.default.removeItem(at: url)
    }

    func test_rename_and_delete_persist() async throws {
        let url = tempURL()
        let store = CollectionStore(fileURL: url, key: key)
        let a = try await store.create(name: "A", now: t0)
        let b = try await store.create(name: "B", now: t0)
        try await store.rename(id: a.id, to: "Alpha")
        try await store.delete(id: b.id)
        let reloaded = CollectionStore(fileURL: url, key: key)
        let all = await reloaded.all()
        XCTAssertEqual(all.map(\.name), ["Alpha"])
        try? FileManager.default.removeItem(at: url)
    }

    func test_missing_file_starts_empty() async {
        let store = CollectionStore(fileURL: tempURL(), key: key)
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func test_plaintext_mode_creates_and_persists_without_encryption_key() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = CollectionStore.plaintextURL(in: directory)
        let store = CollectionStore(fileURL: url, key: nil)

        _ = try await store.create(name: "Test", now: t0)

        let raw = try Data(contentsOf: url)
        XCTAssertEqual(try JSONDecoder().decode([CaptureCollection].self, from: raw).map(\.name),
                       ["Test"])
        let reloaded = CollectionStore(fileURL: url, key: nil)
        let reloadedNames = await reloaded.all().map(\.name)
        XCTAssertEqual(reloadedNames, ["Test"])
    }

    func test_security_mode_migration_roundTripsCollectionList() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plainURL = CollectionStore.plaintextURL(in: directory)
        let sealedURL = CollectionStore.sealedURL(in: directory)
        let plain = CollectionStore(fileURL: plainURL, key: nil)
        _ = try await plain.create(name: "Test", now: t0)

        try CollectionStore.migratePlaintextToSealed(in: directory, key: key)

        XCTAssertFalse(FileManager.default.fileExists(atPath: plainURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedURL.path))
        let encrypted = CollectionStore(fileURL: sealedURL, key: key)
        let encryptedNames = await encrypted.all().map(\.name)
        XCTAssertEqual(encryptedNames, ["Test"])

        try CollectionStore.migrateSealedToPlaintext(in: directory, key: key)

        XCTAssertTrue(FileManager.default.fileExists(atPath: plainURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealedURL.path))
        let decrypted = CollectionStore(fileURL: plainURL, key: nil)
        let decryptedNames = await decrypted.all().map(\.name)
        XCTAssertEqual(decryptedNames, ["Test"])
    }
}
