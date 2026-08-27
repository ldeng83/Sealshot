import XCTest
@testable import Sealshot

@MainActor
final class SealDeleterTests: XCTestCase {

    private func tempSaveFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealDeleterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a tiny placeholder file (we don't need a real .seal package
    /// — SealDeleter only moves the URL).
    private func writeDummy(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x00]).write(to: url)
    }

    func test_delete_movesFileIntoDeletedFolder() throws {
        let saveFolder = tempSaveFolder()
        defer { try? FileManager.default.removeItem(at: saveFolder) }

        let source = saveFolder.appendingPathComponent("capture.seal")
        try writeDummy(at: source)

        let result = try SealDeleter.delete(url: source, saveFolder: saveFolder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(result.lastPathComponent, "capture.seal")
        XCTAssertEqual(result.deletingLastPathComponent().lastPathComponent, "Deleted")
    }

    func test_restore_movesFileBackIntoSaveFolder() throws {
        let saveFolder = tempSaveFolder()
        defer { try? FileManager.default.removeItem(at: saveFolder) }

        let inDeleted = saveFolder.appendingPathComponent("Deleted/capture.seal")
        try writeDummy(at: inDeleted)

        let result = try SealDeleter.restore(url: inDeleted, saveFolder: saveFolder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: inDeleted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(result, saveFolder.appendingPathComponent("capture.seal"))
    }

    func test_delete_suffixesOnNameConflict() throws {
        let saveFolder = tempSaveFolder()
        defer { try? FileManager.default.removeItem(at: saveFolder) }

        // A file with the same basename already exists in Deleted/.
        let existing = saveFolder.appendingPathComponent("Deleted/capture.seal")
        try writeDummy(at: existing)

        let source = saveFolder.appendingPathComponent("capture.seal")
        try writeDummy(at: source)

        let result = try SealDeleter.delete(url: source, saveFolder: saveFolder)

        XCTAssertEqual(result.lastPathComponent, "capture 2.seal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
    }

    func test_restore_suffixesOnNameConflict() throws {
        let saveFolder = tempSaveFolder()
        defer { try? FileManager.default.removeItem(at: saveFolder) }

        let existingInRecent = saveFolder.appendingPathComponent("capture.seal")
        try writeDummy(at: existingInRecent)
        let inDeleted = saveFolder.appendingPathComponent("Deleted/capture.seal")
        try writeDummy(at: inDeleted)

        let result = try SealDeleter.restore(url: inDeleted, saveFolder: saveFolder)

        XCTAssertEqual(result.lastPathComponent, "capture 2.seal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingInRecent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
    }

    func test_permanentlyDelete_removesFile() throws {
        let saveFolder = tempSaveFolder()
        defer { try? FileManager.default.removeItem(at: saveFolder) }

        let target = saveFolder.appendingPathComponent("victim.seal")
        try writeDummy(at: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        try SealDeleter.permanentlyDelete(url: target)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
