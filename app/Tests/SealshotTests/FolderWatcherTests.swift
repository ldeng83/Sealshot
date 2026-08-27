import XCTest
@testable import Sealshot

final class FolderWatcherTests: XCTestCase {

    func test_firesOnFileCreation_onMainQueue() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = FolderWatcher(debounce: 0.05, latency: 0.05)
        let fired = expectation(description: "onChange fired")
        fired.assertForOverFulfill = false
        watcher.onChange = {
            XCTAssertTrue(Thread.isMainThread)
            fired.fulfill()
        }
        watcher.watch(dir)

        // Give the stream a beat to arm before generating the event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            try? Data([1]).write(to: dir.appendingPathComponent("new.png"))
        }
        wait(for: [fired], timeout: 10)
        watcher.stop()
    }

    func test_rewatchSameFolder_isNoop_andStopClears() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = FolderWatcher()
        watcher.watch(dir)
        XCTAssertEqual(watcher.watchedFolder, dir.standardizedFileURL)
        watcher.watch(dir)   // must not crash / re-arm
        watcher.stop()
        XCTAssertNil(watcher.watchedFolder)
    }
}
