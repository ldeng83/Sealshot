import Foundation
import CryptoKit

/// Owns the durable list of `CaptureCollection` records (the cross-capture data:
/// names + order). The list is plaintext in normal mode and sealed when enhanced
/// security is enabled. It is independent of the disposable SQLite index;
/// membership is stored separately, per-capture.
actor CollectionStore {
    static let plaintextFilename = "collections.json"
    static let sealedFilename = "collections.sealed"

    private let fileURL: URL
    private let key: SymmetricKey?
    private var collections: [CaptureCollection]

    init(fileURL: URL, key: SymmetricKey?) {
        self.fileURL = fileURL
        self.key = key
        self.collections = Self.load(fileURL: fileURL, key: key)
    }

    func all() -> [CaptureCollection] {
        collections.sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
    }

    func create(name: String, now: Date) throws -> CaptureCollection {
        let nextIndex = (collections.map(\.sortIndex).max() ?? -1) + 1
        let c = CaptureCollection(id: UUID(), name: name, createdAt: now, sortIndex: nextIndex)
        collections.append(c)
        do {
            try persist()
        } catch {
            collections.removeLast()
            throw error
        }
        return c
    }

    func rename(id: UUID, to name: String) throws {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        let previous = collections[i].name
        collections[i].name = name
        do {
            try persist()
        } catch {
            collections[i].name = previous
            throw error
        }
    }

    func delete(id: UUID) throws {
        let previous = collections
        collections.removeAll { $0.id == id }
        do {
            try persist()
        } catch {
            collections = previous
            throw error
        }
    }

    // MARK: - Persistence

    private func persist() throws {
        let data = try JSONEncoder().encode(collections)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let key {
            let sealed = try SealedBlob.seal(data, with: key)
            try sealed.write(to: fileURL, options: .atomic)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private static func load(fileURL: URL, key: SymmetricKey?) -> [CaptureCollection] {
        guard let stored = try? Data(contentsOf: fileURL) else { return [] }
        let data: Data
        if let key {
            guard let opened = try? SealedBlob.open(stored, with: key) else { return [] }
            data = opened
        } else {
            data = stored
        }
        guard let list = try? JSONDecoder().decode([CaptureCollection].self, from: data)
        else { return [] }
        return list
    }

    // MARK: - Production mode + migration

    static func plaintextURL(in directory: URL) -> URL {
        directory.appendingPathComponent(plaintextFilename)
    }

    static func sealedURL(in directory: URL) -> URL {
        directory.appendingPathComponent(sealedFilename)
    }

    /// Resolve the backing that matches the current security mode. Plain mode
    /// deliberately uses a separate file so an old/unreadable sealed list is
    /// preserved rather than overwritten when the encryption key is absent.
    @MainActor
    static func openCurrentLibraryStore() throws -> CollectionStore {
        let directory = LibraryIndexStore.defaultDatabaseURL.deletingLastPathComponent()
        let session = EncryptionSession.shared
        if session.isEnabled {
            guard let key = try session.contentKey(for: .libraryIndex) else {
                throw CollectionStoreAccessError.libraryLocked
            }
            try migratePlaintextToSealed(in: directory, key: key)
            return CollectionStore(fileURL: sealedURL(in: directory), key: key)
        }
        return CollectionStore(fileURL: plaintextURL(in: directory), key: nil)
    }

    /// Convert the normal-mode JSON list before/while enhanced security is
    /// enabled. Validate the source before replacing the sealed destination;
    /// remove plaintext only after the encrypted atomic write succeeds.
    static func migratePlaintextToSealed(in directory: URL, key: SymmetricKey) throws {
        let source = plaintextURL(in: directory)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let data = try Data(contentsOf: source)
        _ = try JSONDecoder().decode([CaptureCollection].self, from: data)
        let sealed = try SealedBlob.seal(data, with: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try sealed.write(to: sealedURL(in: directory), options: .atomic)
        try FileManager.default.removeItem(at: source)
    }

    /// Convert the sealed list while its key is still available, before
    /// enhanced security retires that key. The encrypted source is removed only
    /// after a validated plaintext atomic write succeeds.
    static func migrateSealedToPlaintext(in directory: URL, key: SymmetricKey) throws {
        let source = sealedURL(in: directory)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let sealed = try Data(contentsOf: source)
        let data = try SealedBlob.open(sealed, with: key)
        _ = try JSONDecoder().decode([CaptureCollection].self, from: data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: plaintextURL(in: directory), options: .atomic)
        try FileManager.default.removeItem(at: source)
    }
}

enum CollectionStoreAccessError: LocalizedError {
    case libraryLocked

    var errorDescription: String? {
        "Unlock the library and try again."
    }
}
