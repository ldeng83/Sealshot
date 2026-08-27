import XCTest
@testable import Sealshot

@MainActor
final class RedactionModelManagerTests: XCTestCase {
    private func fixtureZip(weights: Bool = true) throws -> URL {
        let fm = FileManager.default
        let src = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: src.appendingPathComponent(weights ? "model.safetensors" : "x.txt"))
        let zip = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", src.path, zip.path]; try p.run(); p.waitUntilExit()
        return zip
    }
    private func manager(root: String, sha: String) -> RedactionModelManager {
        RedactionModelManager(version: "v1", root: root, expectedSha256: sha,
                              downloader: NoopDownloader(), checksum: { _ in sha })
    }
    func testFinishDownload_verifyInstallReady() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let m = manager(root: root, sha: "abc")
        try m.finishDownload(tempZip: try fixtureZip())
        guard case .ready(let path) = m.state else { return XCTFail("state=\(m.state)") }
        XCTAssertEqual(path, root + "/v1")
    }
    func testFinishDownload_checksumMismatch_failed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let m = RedactionModelManager(version: "v1", root: root, expectedSha256: "abc",
                                      downloader: NoopDownloader(), checksum: { _ in "WRONG" })
        try? m.finishDownload(tempZip: try fixtureZip())
        guard case .failed = m.state else { return XCTFail("state=\(m.state)") }
    }
    func testRefreshState_readyWhenInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root + "/v1", withIntermediateDirectories: true)
        try Data("w".utf8).write(to: URL(fileURLWithPath: root + "/v1/model.safetensors"))
        let m = manager(root: root, sha: "abc"); m.refreshState()
        guard case .ready = m.state else { return XCTFail("state=\(m.state)") }
    }
    func testRemove_backToNotDownloaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root + "/v1", withIntermediateDirectories: true)
        try Data("w".utf8).write(to: URL(fileURLWithPath: root + "/v1/model.safetensors"))
        let m = manager(root: root, sha: "abc"); m.refreshState(); m.remove()
        guard case .notDownloaded = m.state else { return XCTFail("state=\(m.state)") }
    }
}

private struct NoopDownloader: RedactionModelDownloading {
    func start(from url: URL, onProgress: @escaping (Double) -> Void, onFinish: @escaping (Result<URL, Error>) -> Void) {}
    func cancel() {}
}
