import XCTest
@testable import Sealshot

/// A recording saved without the package wrapper is an ordinary `.mov`/`.mp4`
/// in the save folder. The capture scan feeds BOTH the recent strip and the
/// Library index, so if it doesn't accept those files the recording is
/// invisible in the app — which reads as data loss, not as a setting.
final class PlainMovieCaptureScanTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("plain-movie-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    private func makeFile(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    @discardableResult
    private func makePackage(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scannedNames() -> [String] {
        scanCaptureFiles(in: folder).map { $0.0.lastPathComponent }.sorted()
    }

    func testFindsPlainMovieRecordings() throws {
        try makeFile("clip.mov")
        try makeFile("screen.mp4")

        XCTAssertEqual(scannedNames(), ["clip.mov", "screen.mp4"])
    }

    func testStillFindsImagesAndPackages() throws {
        try makeFile("shot.png")
        try makePackage("capture.seal")
        try makeFile("clip.mov")

        XCTAssertEqual(scannedNames(), ["capture.seal", "clip.mov", "shot.png"])
    }

    func testIgnoresUnrelatedFiles() throws {
        try makeFile("notes.txt")
        try makeFile("archive.zip")
        try makeFile("clip.mkv")   // a movie, but not a container we write

        XCTAssertEqual(scannedNames(), [])
    }

    func testMatchesExtensionsCaseInsensitively() throws {
        try makeFile("LOUD.MOV")

        XCTAssertEqual(scannedNames(), ["LOUD.MOV"])
    }

    /// `.seal` is a directory package; the others must be real files. A folder
    /// merely named `clip.mov` is not a recording.
    func testRejectsADirectoryMasqueradingAsAMovie() throws {
        try makePackage("clip.mov")

        XCTAssertEqual(scannedNames(), [])
    }
}
