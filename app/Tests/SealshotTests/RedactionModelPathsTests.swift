import XCTest
@testable import Sealshot

final class RedactionModelPathsTests: XCTestCase {
    func testInstallDirIsVersionedUnderAppSupport() {
        let dir = RedactionModelPaths.installDir(version: "gliner2-fp16-v1")
        XCTAssertTrue(dir.hasSuffix("/Sealshot/Models/gliner2-fp16/gliner2-fp16-v1"), dir)
        // Anchored to the directory the app itself resolves, not the literal
        // string "Application Support": a test run is deliberately redirected
        // to a temp directory so it cannot touch the user's real library, and
        // hard-coding the location asserted that redirect away.
        XCTAssertTrue(dir.hasPrefix(AppSupportDirectory.sealshot.path), dir)
    }
    func testIsInstalled_trueOnlyWhenSentinelExists() {
        let v = "gliner2-fp16-v1"
        let want = RedactionModelPaths.installDir(version: v) + "/model.safetensors"
        XCTAssertTrue(RedactionModelPaths.isInstalled(version: v, fileExists: { $0 == want }))
        XCTAssertFalse(RedactionModelPaths.isInstalled(version: v, fileExists: { _ in false }))
    }
    func testLocatorReturnsInstalledVersionedDir() {
        let d = UserDefaults(suiteName: "t.\(UUID())")!
        let dir = RedactionModelPaths.installDir(version: RedactionModelSource.current.version)
        let path = RedactionModelLocator.localModelPath(defaults: d, fileExists: { $0 == dir + "/model.safetensors" })
        XCTAssertEqual(path, dir)
    }
    func testSourceHasVersionAndPlaceholdersPresent() {
        XCTAssertFalse(RedactionModelSource.current.version.isEmpty)
        XCTAssertFalse(RedactionModelSource.current.sha256.isEmpty)
    }
}
