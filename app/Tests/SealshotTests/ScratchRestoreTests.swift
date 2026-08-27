import XCTest
@testable import Sealshot

/// Deleting a scratch capture and restoring it must put it BACK in Scratch.
/// Restoring everything to the library root turned "undo a delete" into
/// "keep" — a different decision than the user made, and a silent one.
@MainActor
final class ScratchRestoreTests: XCTestCase {
    private var saveFolder: URL!

    override func setUpWithError() throws {
        saveFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScratchRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saveFolder)
    }

    private func makeCapture(in folder: URL, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try SealContainer.write(entries: [("manifest.json", Data(#"{"version":14}"#.utf8))], to: url)
        return url
    }

    func testScratchCapture_restoresToScratch() throws {
        let scratch = ScratchCapture.folder(under: saveFolder)
        let url = try makeCapture(in: scratch, named: "a.seal")

        let trashed = try SealDeleter.delete(url: url, saveFolder: saveFolder)
        XCTAssertTrue(ScratchCapture.isScratch(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let back = try SealDeleter.restore(url: trashed, saveFolder: saveFolder)
        XCTAssertTrue(ScratchCapture.isScratch(back),
                      "a scratch capture comes back to Scratch, not the Library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: back.path))
    }

    func testLibraryCapture_restoresToTheLibraryRoot() throws {
        let url = try makeCapture(in: saveFolder, named: "b.seal")
        let trashed = try SealDeleter.delete(url: url, saveFolder: saveFolder)

        let back = try SealDeleter.restore(url: trashed, saveFolder: saveFolder)
        XCTAssertEqual(back.deletingLastPathComponent().standardizedFileURL.path,
                       saveFolder.standardizedFileURL.path)
        XCTAssertFalse(ScratchCapture.isScratch(back))
    }

    /// Items trashed before this xattr existed carry no origin — they restore
    /// to the save folder, which is the previous behaviour and the right
    /// fallback.
    func testTrashedItemWithNoRecordedOrigin_restoresToTheLibraryRoot() throws {
        let deleted = saveFolder.appendingPathComponent("Deleted", isDirectory: true)
        let legacy = try makeCapture(in: deleted, named: "old.seal")

        let back = try SealDeleter.restore(url: legacy, saveFolder: saveFolder)
        XCTAssertEqual(back.deletingLastPathComponent().standardizedFileURL.path,
                       saveFolder.standardizedFileURL.path)
    }

    /// The origin is resolved through a whitelist, not by trusting a stored
    /// path: an xattr is user-writable, and "restore wherever this says" is a
    /// way to write outside the library.
    func testTamperedOriginXattr_isIgnored() throws {
        let url = try makeCapture(in: saveFolder, named: "c.seal")
        let trashed = try SealDeleter.delete(url: url, saveFolder: saveFolder)
        let evil = "../../../../tmp"
        _ = evil.withCString { value in
            setxattr(trashed.path, SealDeleter.originalFolderXattr, value, strlen(value), 0, 0)
        }

        let back = try SealDeleter.restore(url: trashed, saveFolder: saveFolder)
        XCTAssertEqual(back.deletingLastPathComponent().standardizedFileURL.path,
                       saveFolder.standardizedFileURL.path,
                       "an unrecognised origin restores to the library, never elsewhere")
    }
}
