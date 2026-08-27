import XCTest
@testable import Sealshot

final class ScanCaptureFilesTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCaptureFilesTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_returnsPNGFilesAndSealDirectories_withMtimes() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("shot.png"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("pkg.seal"), withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("notes.txt"))   // ignored

        let scanned = scanCaptureFiles(in: dir)
        XCTAssertEqual(Set(scanned.map { $0.0.lastPathComponent }),
                       ["shot.png", "pkg.seal"])
        for (_, mtime) in scanned {
            XCTAssertLessThan(abs(mtime.timeIntervalSinceNow), 60)
        }
    }

    func test_missingFolder_returnsEmpty() {
        XCTAssertTrue(scanCaptureFiles(
            in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).isEmpty)
    }

    func test_doesNotReadManifests() throws {
        // A .seal dir with a corrupt manifest must still scan fine — proof the
        // scan is stat-level only.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let seal = dir.appendingPathComponent("broken.seal")
        try FileManager.default.createDirectory(at: seal, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: seal.appendingPathComponent("manifest.json"))

        XCTAssertEqual(scanCaptureFiles(in: dir).count, 1)
    }
}
