import XCTest
@testable import Sealshot

final class QuarantineTests: XCTestCase {
    var saveFolder: URL!

    override func setUpWithError() throws {
        saveFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("q-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: saveFolder) }

    private func makePackage(_ name: String, bytes: Data) throws -> URL {
        let pkg = saveFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try bytes.write(to: pkg.appendingPathComponent("lock.json"))
        return pkg
    }

    func testMovesUnderQuarantineFolderPreservingBytes() throws {
        let pkg = try makePackage("a.seal", bytes: Data([1, 2, 3]))
        let dest = try Quarantine.move(pkg, saveFolder: saveFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pkg.path), "original moved away")
        XCTAssertTrue(dest.path.contains(Quarantine.folderName))
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("lock.json")),
                       Data([1, 2, 3]), "ciphertext preserved")
    }

    func testCollisionSafe() throws {
        let p1 = try makePackage("a.seal", bytes: Data([1]))
        _ = try Quarantine.move(p1, saveFolder: saveFolder)
        let p2 = try makePackage("a.seal", bytes: Data([2]))
        let dest2 = try Quarantine.move(p2, saveFolder: saveFolder)
        XCTAssertEqual(dest2.lastPathComponent, "a-1.seal")
        let folder = saveFolder.appendingPathComponent(Quarantine.folderName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.seal").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a-1.seal").path))
    }

    func testWritesReadmeOnce() throws {
        _ = try Quarantine.move(try makePackage("a.seal", bytes: Data([1])), saveFolder: saveFolder)
        let readme = saveFolder.appendingPathComponent("\(Quarantine.folderName)/README.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: readme.path))
    }
}
