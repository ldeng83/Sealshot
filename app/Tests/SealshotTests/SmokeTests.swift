import XCTest
@testable import Sealshot

final class SmokeTests: XCTestCase {
    func testHostAppIsDockApp() {
        // Sealshot ships as a regular Dock-app (not LSUIElement). Phase 3
        // moved the discoverable surface from the menu-bar tray to the Dock
        // icon — clicking it opens the editor with the most recent capture.
        let info = Bundle.main.infoDictionary
        let value = info?["LSUIElement"] as? Bool
        XCTAssertNotEqual(
            value, true,
            "Sealshot must be a Dock app, not LSUIElement."
        )
    }

    func testHostBundleIdentifier() {
        let id = Bundle.main.bundleIdentifier
        XCTAssertTrue(
            id == "com.seal-shot.sealshot" || id == "com.seal-shot.sealshot.direct",
            "Unexpected bundle id: \(String(describing: id))"
        )
    }

    func testAppEditionResolvesFromBundleID() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let expected: AppEdition = id.hasSuffix(".direct") ? .direct : .mas
        XCTAssertEqual(AppEdition.current, expected)
    }

    func testVersionStringIsPopulated() {
        let s = AppInfo.versionString
        XCTAssertFalse(s.isEmpty)
        XCTAssertNotEqual(s, "? (?)", "MARKETING_VERSION / CURRENT_PROJECT_VERSION not set in Info.plist")
    }

    func testScreenCaptureUsageDescriptionPresent() {
        let description = Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String
        XCTAssertNotNil(description, "Info.plist must declare NSScreenCaptureUsageDescription")
        XCTAssertFalse((description ?? "").isEmpty)
    }
}
