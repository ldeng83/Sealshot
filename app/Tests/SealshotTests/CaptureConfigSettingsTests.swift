import XCTest
@testable import Sealshot

@MainActor
final class CaptureConfigSettingsTests: XCTestCase {

    private func freshConfig() -> CaptureConfig {
        // Clear the keys so each test starts from defaults.
        let d = UserDefaults.standard
        for k in ["captureConfig.defaultOutput", "captureConfig.saveFolder",
                  "captureConfig.filenameFormat", "captureConfig.retentionDays"] {
            d.removeObject(forKey: k)
        }
        return CaptureConfig()
    }

    func testRetentionDays_matchesDefault() {
        XCTAssertEqual(freshConfig().retentionDays, CaptureConfig.defaultRetentionDays)
        XCTAssertEqual(CaptureConfig.defaultRetentionDays, 7)
    }

    func testRetentionDays_clampsToAtLeastOne() {
        let c = freshConfig()
        c.retentionDays = 0
        XCTAssertEqual(c.retentionDays, 1)
        c.retentionDays = -5
        XCTAssertEqual(c.retentionDays, 1)
        // Clamped value must persist: a fresh config reading UserDefaults sees 1, not the default.
        XCTAssertEqual(CaptureConfig().retentionDays, 1)
    }

    func testRetentionDays_clampsToAtMost365() {
        let c = freshConfig()
        c.retentionDays = 366
        XCTAssertEqual(c.retentionDays, 365)
        c.retentionDays = 9999
        XCTAssertEqual(c.retentionDays, 365)
        // Clamped value must persist, mirroring the lower-bound behavior.
        XCTAssertEqual(CaptureConfig().retentionDays, 365)
    }

    func testRetentionDays_initClampsStoredValueAboveRange() {
        _ = freshConfig()
        // A stored value written by an older build (no upper clamp) must load capped.
        UserDefaults.standard.set(400, forKey: "captureConfig.retentionDays")
        XCTAssertEqual(CaptureConfig().retentionDays, 365)
    }

    func testRetentionDays_inRangeValuesUnchanged() {
        let c = freshConfig()
        for v in [1, 30, 365] {
            c.retentionDays = v
            XCTAssertEqual(c.retentionDays, v)
        }
    }

    func testResetToDefaults_restoresOutputFolderFilenameRetention() {
        let c = freshConfig()
        c.defaultOutput = .clipboard
        c.filenameFormat = "custom"
        c.retentionDays = 99
        c.resetToDefaults()
        XCTAssertEqual(c.defaultOutput, .both)
        XCTAssertEqual(c.filenameFormat, CaptureConfig.defaultFilenameFormat)
        XCTAssertEqual(c.saveFolder, CaptureConfig.defaultSaveFolder)
        XCTAssertEqual(c.retentionDays, CaptureConfig.defaultRetentionDays)
    }

    func testRenderFilename_usesFormatAndExtension() {
        let c = freshConfig()
        c.filenameFormat = "'shot' yyyy"
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023
        XCTAssertEqual(c.renderFilename(extension: "seal", at: date), "shot 2023.seal")
    }
}
