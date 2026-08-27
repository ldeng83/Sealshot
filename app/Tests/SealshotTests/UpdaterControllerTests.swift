import XCTest
@testable import Sealshot

/// The test suite runs against the MAS target, which must not link Sparkle —
/// so the inert stub surface is what's under test here. The Direct (Sparkle)
/// side is covered by the Direct build gate and the manual update check.
@MainActor
final class UpdaterControllerTests: XCTestCase {
    func testMASBuildCannotCheckForUpdates() {
        XCTAssertFalse(UpdaterController.shared.canCheckForUpdates)
    }

    func testAutomaticChecksToggleIsInertInMAS() {
        let updater = UpdaterController.shared
        XCTAssertFalse(updater.automaticallyChecksForUpdates) // precondition
        updater.automaticallyChecksForUpdates = true
        XCTAssertFalse(updater.automaticallyChecksForUpdates) // setter must be a no-op
    }

    func testCheckForUpdatesIsSafeNoOpInMAS() {
        UpdaterController.shared.checkForUpdates() // must not crash or alert
    }

    func testStartUpdaterIsSafeNoOpInMAS() {
        UpdaterController.shared.startUpdater() // must not crash
    }

    func testMASBuildDoesNotSupportUpdates() {
        XCTAssertFalse(UpdaterController.shared.updatesAreSupported)
    }

    func testCurrentVersionStringContainsMarketingAndBuild() throws {
        let info = Bundle.main.infoDictionary
        let short = try XCTUnwrap(info?["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info?["CFBundleVersion"] as? String)
        let version = UpdaterController.shared.currentVersionString
        XCTAssertTrue(version.contains(short))
        XCTAssertTrue(version.contains(build))
    }
}
