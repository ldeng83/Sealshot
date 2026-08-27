import XCTest
@testable import Sealshot

final class RecordingsLibraryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, modified: Date) throws {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func test_listsOnlyVideos_newestFirst() throws {
        try write("a.mov", modified: Date(timeIntervalSince1970: 100))
        try write("b.mp4", modified: Date(timeIntervalSince1970: 300))
        try write("c.mov", modified: Date(timeIntervalSince1970: 200))
        try write("notes.txt", modified: Date(timeIntervalSince1970: 999))   // ignored
        try write("thumb.png", modified: Date(timeIntervalSince1970: 999))   // ignored

        let items = RecordingsLibrary.items(in: dir)
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["b.mp4", "c.mov", "a.mov"])
        XCTAssertEqual(items.first?.name, "b")   // extension stripped
    }

    func test_missingFolder_returnsEmpty() {
        let gone = dir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(RecordingsLibrary.items(in: gone), [])
    }

    func test_extensionMatchIsCaseInsensitive() throws {
        try write("UPPER.MOV", modified: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(RecordingsLibrary.items(in: dir).count, 1)
    }

    func test_sealrec_isListedAndFlaggedEncrypted() throws {
        try write("plain.mov", modified: Date(timeIntervalSince1970: 100))
        try write("secret.sealrec", modified: Date(timeIntervalSince1970: 200))
        let items = RecordingsLibrary.items(in: dir)
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["secret.sealrec", "plain.mov"])
        XCTAssertEqual(items.first { $0.name == "secret" }?.isEncrypted, true)
        XCTAssertEqual(items.first { $0.name == "plain" }?.isEncrypted, false)
    }

    func test_folderPath_isRecordingsSubdir() {
        let save = URL(fileURLWithPath: "/tmp/Sealshot", isDirectory: true)
        XCTAssertEqual(RecordingsLibrary.folder(forSaveFolder: save).lastPathComponent, "Recordings")
    }
}
