import XCTest
@testable import Sealshot

/// Captures kept OUT of the Library: destination routing, the keep gesture,
/// and the purge. All against temp directories — no real library is touched.
final class ScratchCaptureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScratchCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Routing

    func testDestination_onMeansTheSaveFolderItself() {
        XCTAssertEqual(ScratchCapture.destination(saveFolder: root, addToLibrary: true), root)
    }

    func testDestination_offMeansTheScratchSubfolder() {
        let dest = ScratchCapture.destination(saveFolder: root, addToLibrary: false)
        XCTAssertEqual(dest.lastPathComponent, "Scratch")
        XCTAssertEqual(dest.deletingLastPathComponent().path, root.path,
                       "a SUBFOLDER of the save folder: same volume (keep = rename), "
                       + "same crypto path, invisible to the per-folder Library index")
    }

    func testIsScratch_recognisesOnlyTheScratchFolder() {
        let scratch = ScratchCapture.folder(under: root).appendingPathComponent("a.seal")
        XCTAssertTrue(ScratchCapture.isScratch(scratch))
        XCTAssertFalse(ScratchCapture.isScratch(root.appendingPathComponent("a.seal")))
        XCTAssertFalse(ScratchCapture.isScratch(
            root.appendingPathComponent("Deleted/a.seal")))
    }

    // MARK: The preference

    func testPreference_defaultsToAddingToLibrary() {
        let name = "ScratchCaptureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(ScratchCapturePreference(defaults: defaults).addsToLibrary,
                      "captures joining the Library is what every user has today")
        defaults.set(false, forKey: ScratchCapturePreference.key)
        XCTAssertFalse(ScratchCapturePreference(defaults: defaults).addsToLibrary)
    }

    // MARK: The keep gesture

    func testKeep_movesTheFileIntoTheSaveFolder() throws {
        let scratch = ScratchCapture.folder(under: root)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("shot.seal")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

        let dest = try ScratchCapture.keep(file, saveFolder: root)
        XCTAssertEqual(dest.deletingLastPathComponent().path, root.path)
        XCTAssertEqual(dest.lastPathComponent, "shot.seal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "moved, not copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    /// Keeping must never overwrite a library capture that shares the name.
    func testKeep_dedupesAgainstAnExistingLibraryFile() throws {
        let scratch = ScratchCapture.folder(under: root)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("shot.seal")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        // A library capture already named shot.seal.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("shot.seal"), withIntermediateDirectories: true)

        let dest = try ScratchCapture.keep(file, saveFolder: root)
        XCTAssertNotEqual(dest.lastPathComponent, "shot.seal",
                          "the existing capture keeps its name; the kept one dedupes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("shot.seal").path), "untouched")
    }

    // MARK: Purge

    private func scratchFile(_ name: String, ageDays: Double) throws -> URL {
        let scratch = ScratchCapture.folder(under: root)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageDays * 24 * 3600)],
            ofItemAtPath: url.path)
        return url
    }

    func testPurge_removesOnlyEntriesPastRetention() throws {
        let old = try scratchFile("old.seal", ageDays: 8)
        let fresh = try scratchFile("fresh.seal", ageDays: 2)

        let removed = ScratchCapture.purge(in: root)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "inside the window, still the user's to keep")
    }

    func testPurge_withNoScratchFolder_isANoOp() {
        XCTAssertEqual(ScratchCapture.purge(in: root), 0)
    }

    /// The purge must never reach outside Scratch/ — the save folder around it
    /// is the LIBRARY.
    func testPurge_neverTouchesTheLibraryAroundIt() throws {
        let library = root.appendingPathComponent("keeper.seal")
        try Data("x".utf8).write(to: library)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)],
            ofItemAtPath: library.path)
        _ = try scratchFile("old.seal", ageDays: 30)

        _ = ScratchCapture.purge(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
    }

    // MARK: Library section

    /// Scratch is a real sidebar section (above Trash) backed by its folder,
    /// so "where did my capture go" always has a visible answer.
    @MainActor
    func testLibrarySection_scratchMapsToTheScratchFolder() {
        XCTAssertEqual(libraryFolder(for: .scratch, saveFolder: root),
                       ScratchCapture.folder(under: root))
        XCTAssertTrue(LibrarySection.scratch.isScratch)
        XCTAssertFalse(LibrarySection.trash.isScratch)
    }

    /// The row shows whenever the mode is on OR items exist: an empty Scratch
    /// is meaningful the moment captures start bypassing the Library, and
    /// stays discoverable while anything is still waiting in it.
    func testScratchRowVisibility() {
        XCTAssertTrue(scratchRowVisible(hasItems: false, capturesAddToLibrary: false),
                      "mode on: the row IS the answer to where captures go")
        XCTAssertTrue(scratchRowVisible(hasItems: true, capturesAddToLibrary: true),
                      "mode back on but items remain: still reachable")
        XCTAssertFalse(scratchRowVisible(hasItems: false, capturesAddToLibrary: true),
                       "never used: invisible")
    }

    /// The presence half of that gate.
    func testScratchPresence_requiresASealPackage() throws {
        XCTAssertFalse(ScratchPresence.hasItems(saveFolder: root), "no folder")
        let scratch = ScratchCapture.folder(under: root)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        XCTAssertFalse(ScratchPresence.hasItems(saveFolder: root), "empty folder")
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("a.seal"), withIntermediateDirectories: true)
        XCTAssertTrue(ScratchPresence.hasItems(saveFolder: root))
    }

    // MARK: Recordings

    /// Recordings get their OWN switch. One toggle for both would tie a
    /// gigabyte-scale decision to a kilobyte-scale one.
    func testRecordingPreference_isSeparateAndDefaultsOn() {
        let name = "ScratchCaptureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = ScratchCapturePreference(defaults: defaults)
        XCTAssertTrue(prefs.recordingsAddToLibrary)

        defaults.set(false, forKey: ScratchCapturePreference.recordingKey)
        XCTAssertFalse(ScratchCapturePreference(defaults: defaults).recordingsAddToLibrary)
        XCTAssertTrue(ScratchCapturePreference(defaults: defaults).addsToLibrary,
                      "captures are unaffected by the recording switch")
    }

    // MARK: Size

    /// The sidebar shows what is waiting, because it is on a 7-day timer and
    /// recordings make the number large.
    func testTotalSize_sumsPackagesIncludingTheirContents() throws {
        let scratch = ScratchCapture.folder(under: root)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // A `.seal` is a directory package: its size is the sum of its parts.
        let package = scratch.appendingPathComponent("clip.seal")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2_048).write(to: package.appendingPathComponent("video.bin"))
        try Data(repeating: 7, count: 512).write(to: package.appendingPathComponent("manifest.json"))
        try Data(repeating: 7, count: 1_024).write(to: scratch.appendingPathComponent("loose.png"))

        XCTAssertEqual(ScratchCapture.totalSize(in: root), 3_584)
    }

    func testTotalSize_isZeroWithoutAScratchFolder() {
        XCTAssertEqual(ScratchCapture.totalSize(in: root), 0)
    }

    // MARK: Sidebar size labels

    /// Sizes belong to sections that OWN their files. Recents is a window onto
    /// All Files and Collections overlap each other, so a size on either would
    /// be double-counting dressed up as information.
    @MainActor
    func testSizeLabels_onlyForSectionsThatOwnTheirFiles() {
        for section in [LibrarySection.recents, .collections, .lockedArchive] {
            XCTAssertNil(LibraryViewModel.sizeLabel(bytes: 5_000, for: section),
                         "\(section) must not claim a size")
        }
        for section in [LibrarySection.allFiles, .trash, .scratch] {
            XCTAssertNotNil(LibraryViewModel.sizeLabel(bytes: 5_000, for: section))
        }
    }

    /// Empty means no label at all, not "Zero KB" beside every row.
    @MainActor
    func testSizeLabel_isNilWhenEmpty() {
        XCTAssertNil(LibraryViewModel.sizeLabel(bytes: 0, for: .allFiles))
    }

    // MARK: The announcement seam

    /// `presentCaptured` announces library captures (index, strips, ⌘Z) and
    /// must stay silent for scratch ones — "not in the Library" is exactly the
    /// absence of that announcement.
    func testScratchURLs_areNotAnnounced() {
        let scratch = ScratchCapture.folder(under: root).appendingPathComponent("a.seal")
        XCTAssertTrue(ScratchCapture.isScratch(scratch), "the guard presentCaptured uses")
        XCTAssertFalse(ScratchCapture.isScratch(root.appendingPathComponent("a.seal")))
    }
}
