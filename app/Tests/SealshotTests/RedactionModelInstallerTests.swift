import XCTest
@testable import Sealshot

final class RedactionModelInstallerTests: XCTestCase {
    private func run(_ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = args
        try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0)
    }
    func testInstallsZipContentsIntoVersionedDir() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let src = work.appendingPathComponent("payload"); let root = work.appendingPathComponent("root").path
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: src.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: src.appendingPathComponent("config.json"))
        let zip = work.appendingPathComponent("m.zip")
        try run(["-c", "-k", src.path, zip.path])   // zip the payload dir

        let installed = try RedactionModelInstaller.install(zipAt: zip, version: "v1", into: root)
        XCTAssertEqual(installed, root + "/v1")
        XCTAssertTrue(fm.fileExists(atPath: installed + "/model.safetensors"))
        XCTAssertTrue(fm.fileExists(atPath: installed + "/config.json"))
    }
    func testReplacesExistingInstall() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = work.appendingPathComponent("root").path
        try fm.createDirectory(atPath: root + "/v1", withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: root + "/v1/old.txt"))
        let src = work.appendingPathComponent("p"); try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: src.appendingPathComponent("model.safetensors"))
        let zip = work.appendingPathComponent("m.zip"); try run(["-c", "-k", src.path, zip.path])
        let installed = try RedactionModelInstaller.install(zipAt: zip, version: "v1", into: root)
        XCTAssertFalse(fm.fileExists(atPath: installed + "/old.txt"))  // replaced, not merged
        XCTAssertTrue(fm.fileExists(atPath: installed + "/model.safetensors"))
    }
    func testThrowsWhenWeightsMissing() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let src = work.appendingPathComponent("p"); try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: src.appendingPathComponent("readme.txt"))
        let zip = work.appendingPathComponent("m.zip"); try run(["-c", "-k", src.path, zip.path])
        XCTAssertThrowsError(try RedactionModelInstaller.install(zipAt: zip, version: "v1", into: work.appendingPathComponent("root").path))
    }
}
