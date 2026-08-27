import XCTest
@testable import Sealshot

/// `sealPackageSize` sums the bytes inside a `.seal` package directory bundle.
final class SealPackageSizeTests: XCTestCase {

    func test_sumsFileBytesInPackage() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seal-size-\(UUID().uuidString).seal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 100).write(to: dir.appendingPathComponent("source.png"))
        try Data(count: 50).write(to: dir.appendingPathComponent("manifest.json"))

        XCTAssertEqual(sealPackageSize(at: dir), 150)
    }

    func test_missingPath_isNil() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).seal")
        XCTAssertNil(sealPackageSize(at: missing))
    }
}
