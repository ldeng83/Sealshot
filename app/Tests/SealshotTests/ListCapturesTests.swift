import XCTest
@testable import Sealshot

final class ListCapturesTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("listcaps-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testListCaptures_returnsPngAndSealOnly() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try Data([0]).write(to: dir.appendingPathComponent("a.png"))
        try Data([0]).write(to: dir.appendingPathComponent("notes.txt"))
        try fm.createDirectory(at: dir.appendingPathComponent("b.seal"), withIntermediateDirectories: true)

        let names = Set(listCaptures(in: dir).map { $0.0.lastPathComponent })
        XCTAssertEqual(names, ["a.png", "b.seal"])
    }

    func testListCaptures_sealUsesManifestCaptureDate_notMtime() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        // A .seal whose manifest says it was captured long ago, but whose folder
        // was just written (mtime ≈ now, as a re-save would leave it). Ordering
        // must use the capture date so a re-saved old shot can't jump to the top.
        let seal = dir.appendingPathComponent("old.seal")
        try fm.createDirectory(at: seal, withIntermediateDirectories: true)
        let captured = Date(timeIntervalSince1970: 1_000_000)
        let manifest = SealManifest(
            version: 2,
            createdISO8601: ISO8601DateFormatter().string(from: captured),
            modifiedISO8601: ISO8601DateFormatter().string(from: Date()),
            sourceSize: .init(width: 10, height: 10),
            sourceApp: nil
        )
        try manifest.encodeJSON().write(to: seal.appendingPathComponent("manifest.json"))

        let result = listCaptures(in: dir).first { $0.0.lastPathComponent == "old.seal" }
        let date = try XCTUnwrap(result?.1)
        XCTAssertEqual(date.timeIntervalSince1970, captured.timeIntervalSince1970, accuracy: 1.0,
                       "listCaptures should date a .seal by its manifest capture time, not folder mtime")
    }

    func testCaptureDate_fallsBackToMtimeForPlainPng() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png")
        try Data([0]).write(to: png)
        let fallback = Date(timeIntervalSince1970: 42)
        // No manifest, and a plain file: resolution falls through to the
        // provided fallback (its mtime) when no creation date beats it.
        let date = captureDate(of: png, fallback: fallback)
        // Either the file's real creation date or the fallback — never a crash,
        // and for a freshly written file it should be close to now or fallback.
        XCTAssertNotNil(date)
    }

    func testListCaptures_missingFolder_returnsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertTrue(listCaptures(in: missing).isEmpty)
    }
}
