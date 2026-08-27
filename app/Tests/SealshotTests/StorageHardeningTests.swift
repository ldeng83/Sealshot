import XCTest
@testable import Sealshot

final class StorageHardeningTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testAppliesSpotlightMarkerAndPermissions() throws {
        StorageHardening.apply(to: dir)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(".metadata_never_index").path))
        let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
    }

    func testIdempotent() {
        StorageHardening.apply(to: dir)
        StorageHardening.apply(to: dir)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(".metadata_never_index").path))
    }

    func testMissingFolderIsNoOp() {
        StorageHardening.apply(to: dir.appendingPathComponent("nope"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("nope").path))
    }
}
