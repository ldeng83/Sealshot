import XCTest
@testable import Sealshot

/// Section→folder mapping and makeLibraryItems behaviour.
final class LibraryModelTests: XCTestCase {

    func testFolder_allShotsAndRecents_useSaveFolder() {
        let save = URL(fileURLWithPath: "/save")
        XCTAssertEqual(libraryFolder(for: .allFiles, saveFolder: save), save)
        XCTAssertEqual(libraryFolder(for: .recents, saveFolder: save), save)
    }

    func testFolder_trash_usesDeletedSubfolder() {
        let save = URL(fileURLWithPath: "/save")
        XCTAssertEqual(
            libraryFolder(for: .trash, saveFolder: save),
            save.appendingPathComponent("Deleted", isDirectory: true))
    }

    func testFolder_lockedArchive_usesQuarantineFolder() {
        let save = URL(fileURLWithPath: "/save")
        XCTAssertEqual(
            libraryFolder(for: .lockedArchive, saveFolder: save),
            save.appendingPathComponent(Quarantine.folderName, isDirectory: true))
    }

    // MARK: - LockedArchivePresence (Task 5): sidebar visibility helper

    func testLockedArchivePresence_noFolder_isFalse() {
        let save = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockedArchivePresence-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(LockedArchivePresence.hasItems(saveFolder: save))
    }

    func testLockedArchivePresence_emptyFolder_isFalse() throws {
        let save = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockedArchivePresence-\(UUID().uuidString)", isDirectory: true)
        let quarantine = save.appendingPathComponent(Quarantine.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: save) }
        XCTAssertFalse(LockedArchivePresence.hasItems(saveFolder: save))
    }

    func testLockedArchivePresence_folderWithNonSealFile_isFalse() throws {
        let save = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockedArchivePresence-\(UUID().uuidString)", isDirectory: true)
        let quarantine = save.appendingPathComponent(Quarantine.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: save) }
        try Data("readme".utf8).write(to: quarantine.appendingPathComponent("README.txt"))
        XCTAssertFalse(LockedArchivePresence.hasItems(saveFolder: save))
    }

    func testLockedArchivePresence_folderWithSealPackage_isTrue() throws {
        let save = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockedArchivePresence-\(UUID().uuidString)", isDirectory: true)
        let quarantine = save.appendingPathComponent(Quarantine.folderName, isDirectory: true)
        let pkg = quarantine.appendingPathComponent("shot.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: save) }
        XCTAssertTrue(LockedArchivePresence.hasItems(saveFolder: save))
    }

    // MARK: - makeLibraryItems: captureKind → isVideo + durationSeconds

    private func makeRow(path: String, captureKind: CaptureKind? = nil,
                         durationSeconds: Double = 0,
                         tags: [String] = [], smartKeywords: [String] = []) -> CaptureIndexRow {
        CaptureIndexRow(path: path, folder: "/save",
                        mtime: Date(timeIntervalSince1970: 1),
                        captureDate: Date(timeIntervalSince1970: 1),
                        userTitle: nil, title: path,
                        tags: tags, smartKeywords: smartKeywords,
                        captureKind: captureKind,
                        durationSeconds: durationSeconds)
    }

    // MARK: - makeLibraryItems: search matches tags and smartKeywords (Task 5)

    func test_search_matches_smartKeywords_and_tags() {
        let rows = [
            makeRow(path: "/save/a.seal", tags: ["alpha"], smartKeywords: []),
            makeRow(path: "/save/b.seal", tags: [], smartKeywords: ["beta"])
        ]
        let alphaHits = makeLibraryItems(rows: rows, section: .allFiles,
                                         search: "alpha", now: Date())
            .map { $0.url.lastPathComponent }
        XCTAssertEqual(alphaHits, ["a.seal"])

        let betaHits = makeLibraryItems(rows: rows, section: .allFiles,
                                        search: "beta", now: Date())
            .map { $0.url.lastPathComponent }
        XCTAssertEqual(betaHits, ["b.seal"])
    }

    func testMakeLibraryItems_screenRecordingRow_isVideoWithDuration() {
        let row = makeRow(path: "/save/rec.seal", captureKind: .screenRecording, durationSeconds: 42.5)
        let items = makeLibraryItems(rows: [row], section: .allFiles, search: "", now: Date())
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertTrue(item.isVideo, "screenRecording row should produce isVideo=true")
        XCTAssertEqual(item.durationSeconds, 42.5)
    }

    func testMakeLibraryItems_importedVideoRow_isVideoWithDuration() {
        let row = makeRow(path: "/save/vid.seal", captureKind: .importedVideo, durationSeconds: 10.0)
        let items = makeLibraryItems(rows: [row], section: .allFiles, search: "", now: Date())
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isVideo)
        XCTAssertEqual(items[0].durationSeconds, 10.0)
    }

    func testMakeLibraryItems_screenshotRow_isNotVideo_noDuration() {
        let row = makeRow(path: "/save/shot.seal", captureKind: .screenshot, durationSeconds: 0)
        let items = makeLibraryItems(rows: [row], section: .allFiles, search: "", now: Date())
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].isVideo)
        XCTAssertNil(items[0].durationSeconds)
    }

    func testMakeLibraryItems_nilCaptureKindRow_isNotVideo() {
        let row = makeRow(path: "/save/shot.seal", captureKind: nil)
        let items = makeLibraryItems(rows: [row], section: .allFiles, search: "", now: Date())
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].isVideo)
        XCTAssertNil(items[0].durationSeconds)
    }

    // MARK: - Section type filter
    // Note: media discrimination (images vs videos) moved to StripMediaFilter (Task 2).
    // All sections now show both images and videos; only allFiles/recents/collections/trash exist.

    func testSectionFilter_allFilesSection_includesBoth() {
        let rows = [
            makeRow(path: "/save/shot.seal", captureKind: .screenshot),
            makeRow(path: "/save/rec.seal",  captureKind: .screenRecording),
        ]
        let items = makeLibraryItems(rows: rows, section: .allFiles, search: "", now: Date())
        XCTAssertEqual(items.count, 2)
    }

    func testSectionFilter_recentsSection_includesBoth() {
        let now = Date()
        // makeRow uses epoch as captureDate, so it would be filtered out by
        // the recents window. Build rows with captureDate = now instead.
        let recentRow1 = CaptureIndexRow(path: "/save/shot.seal", folder: "/save",
                                         mtime: now, captureDate: now,
                                         userTitle: nil, title: "", tags: [],
                                         captureKind: .screenshot)
        let recentRow2 = CaptureIndexRow(path: "/save/rec.seal", folder: "/save",
                                         mtime: now, captureDate: now,
                                         userTitle: nil, title: "", tags: [],
                                         captureKind: .screenRecording)
        let items = makeLibraryItems(rows: [recentRow1, recentRow2], section: .recents,
                                     search: "", now: now)
        XCTAssertEqual(items.count, 2)
    }

    // MARK: - makeLibraryItems: dimensions and sourceApp

    private func row(_ path: String, width: Int, height: Int, app: String?) -> CaptureIndexRow {
        CaptureIndexRow(path: path, folder: "/lib",
                        mtime: Date(timeIntervalSince1970: 0),
                        captureDate: Date(timeIntervalSince1970: 0),
                        userTitle: nil, title: "t", tags: [],
                        width: width, height: height, sourceApp: app)
    }

    func testMapsDimensionsAndSourceApp() {
        let items = makeLibraryItems(
            rows: [row("/lib/a.seal", width: 2560, height: 1440, app: "Safari")],
            section: .allFiles, search: "", now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].width, 2560)
        XCTAssertEqual(items[0].height, 1440)
        XCTAssertEqual(items[0].sourceApp, "Safari")
        XCTAssertEqual(items[0].dimensions?.w, 2560)
    }

    func testDimensionsNilWhenZero() {
        let items = makeLibraryItems(
            rows: [row("/lib/b.seal", width: 0, height: 0, app: nil)],
            section: .allFiles, search: "", now: Date(timeIntervalSince1970: 100))
        XCTAssertNil(items[0].dimensions)
        XCTAssertNil(items[0].sourceApp)
    }
}
