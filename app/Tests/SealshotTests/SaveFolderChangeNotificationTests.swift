import XCTest
@testable import Sealshot

/// The save folder is the one setting that invalidates what every surface is
/// showing — canvas, recent strip, and Library all list the OLD library until
/// they are told. That broadcast is the contract these tests pin down.
@MainActor
final class SaveFolderChangeNotificationTests: XCTestCase {

    private var config: CaptureConfig!
    private var originalFolder: URL!

    override func setUp() {
        super.setUp()
        config = CaptureConfig()
        originalFolder = config.saveFolder
    }

    override func tearDown() {
        // CaptureConfig persists into UserDefaults.standard — put the real
        // save folder back so the suite can't repoint the host app's library.
        config.saveFolder = originalFolder
        config = nil
        super.tearDown()
    }

    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveFolderChangeTests-\(UUID().uuidString)", isDirectory: true)
    }

    func test_changingTheFolderBroadcastsTheNewLocation() {
        let target = tempFolder()
        var received: [URL] = []
        let token = NotificationCenter.default.addObserver(
            forName: .saveFolderDidChange, object: nil, queue: nil
        ) { note in
            if let url = note.object as? URL { received.append(url) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        config.saveFolder = target

        XCTAssertEqual(received, [target],
                       "observers must be handed the NEW folder, once")
    }

    func test_rewritingTheSameFolderBroadcastsNothing() {
        // Settings re-assigns on every visit to the pane. Without the guard,
        // each one would blow away the open capture and reload the Library.
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: .saveFolderDidChange, object: nil, queue: nil
        ) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        config.saveFolder = config.saveFolder

        XCTAssertEqual(count, 0, "a no-op assignment must not invalidate anything")
    }

    func test_theNewFolderIsPersisted() {
        let target = tempFolder()
        config.saveFolder = target
        // Compared by path: UserDefaults round-trips a directory URL with a
        // trailing slash the original doesn't have.
        XCTAssertEqual(CaptureConfig().saveFolder.path, target.path,
                       "a fresh config must read back the folder just set")
    }

    func test_theSameFolderReadBackFromDefaultsIsNotTreatedAsAChange() {
        // The trailing-slash round-trip above must not look like a real move,
        // or simply reopening Settings would close the user's open capture.
        let target = tempFolder()
        config.saveFolder = target
        let roundTripped = CaptureConfig().saveFolder

        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: .saveFolderDidChange, object: nil, queue: nil
        ) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        config.saveFolder = roundTripped

        XCTAssertEqual(count, 0, "same folder, different URL spelling — not a change")
    }
}
