import XCTest
@testable import Sealshot

private typealias LibraryItem = Sealshot.LibraryItem

/// Tests for the section→folder mapping and the Trash round-trip for legacy recordings.
/// Note: mergedLibraryItems / recordingsFolder were retired in SP-D slice 5b —
/// their section-type-filter role moved into makeLibraryItems; tests for that
/// new behaviour live in LibraryModelTests.
final class LibraryMergeTests: XCTestCase {

    // MARK: - section → folder mapping

    func testLibraryFolderMapping() {
        let save = URL(fileURLWithPath: "/save")
        for s in [LibrarySection.allFiles, .recents, .collections] {
            XCTAssertEqual(libraryFolder(for: s, saveFolder: save), save)
        }
        XCTAssertEqual(libraryFolder(for: .trash, saveFolder: save),
                       save.appendingPathComponent("Deleted", isDirectory: true))
        XCTAssertEqual(libraryFolder(for: .lockedArchive, saveFolder: save),
                       save.appendingPathComponent(Quarantine.folderName, isDirectory: true))
    }
}

@MainActor
final class RecordingTrashTests: XCTestCase {
    func testDeleteThenRestoreRoundTripsToRecordings() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rectrash-\(UUID().uuidString)", isDirectory: true)
        let recordings = RecordingsLibrary.folder(forSaveFolder: base)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let clip = recordings.appendingPathComponent("clip.sealrec")
        try Data([1, 2, 3]).write(to: clip)

        // Delete → moves to Deleted/ (where the Trash section scans).
        let trashed = try SealDeleter.delete(url: clip, saveFolder: base)
        XCTAssertTrue(trashed.path.contains("Deleted"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))

        // Restore → back to Recordings/, not the save-folder root.
        let back = try SealDeleter.restore(url: trashed, toFolder: recordings)
        XCTAssertEqual(back.deletingLastPathComponent().lastPathComponent, "Recordings")
        XCTAssertEqual(try Data(contentsOf: back), Data([1, 2, 3]))
    }
}
