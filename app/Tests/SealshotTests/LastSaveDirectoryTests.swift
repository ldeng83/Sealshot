import XCTest
@testable import Sealshot

final class LastSaveDirectoryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: LastSaveDirectory.key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LastSaveDirectory.key)
        super.tearDown()
    }

    func testDefaultsToNil() {
        XCTAssertNil(LastSaveDirectory.url)
    }

    func testRemembersTheFolderOfASavedFile() {
        let tmp = FileManager.default.temporaryDirectory
        LastSaveDirectory.remember(tmp.appendingPathComponent("Sealshot Export.png"))
        XCTAssertEqual(LastSaveDirectory.url?.standardizedFileURL, tmp.standardizedFileURL)
    }

    func testForgetsADirectoryThatNoLongerExists() {
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("sealshot-does-not-exist-\(UUID().uuidString)", isDirectory: true)
        LastSaveDirectory.url = gone
        // Persisted, but the getter drops it because the folder is missing.
        XCTAssertNil(LastSaveDirectory.url)
    }
}
