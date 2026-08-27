import XCTest
@testable import Sealshot

/// Per-tab settings reset scopes (and Reset All = their union). Runs against
/// an isolated defaults suite; the SMAppService / Sparkle / KeyboardShortcuts
/// side effects only fire against `.standard`, so tests stay hermetic.
@MainActor
final class SettingsResetTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsResetTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_resetGeneral_restoresTour_leavesAIScopeAlone() {
        WelcomePreference.setTourEnabled(false, into: defaults)
        AIFeaturePreference(defaults: defaults).enabled = false

        SettingsReset.resetGeneral(config: CaptureConfig(), defaults: defaults)

        XCTAssertTrue(WelcomePreference.tourEnabled(defaults))
        XCTAssertFalse(AIFeaturePreference(defaults: defaults).enabled,
                       "AI settings live on the On-Device AI tab; General reset must not touch them")
    }

    func test_resetAI_restoresToggleThoroughAndAutoScan() {
        AIFeaturePreference(defaults: defaults).enabled = false
        ThoroughScanPreference(defaults: defaults).enabled = true
        SmartRedactionPreference.setAutoScan(true, into: defaults)

        SettingsReset.resetAI(defaults: defaults)

        XCTAssertTrue(AIFeaturePreference(defaults: defaults).enabled)
        XCTAssertFalse(ThoroughScanPreference(defaults: defaults).enabled)
        XCTAssertFalse(SmartRedactionPreference.autoScanEnabled(defaults))
    }

    func test_resetCapture_restoresAutoScrollAndFilenameTitle_leavesAutoScanAlone() {
        AutoScrollPreference.set(false, into: defaults)
        SmartRedactionPreference.setAutoScan(true, into: defaults)
        FilenameIncludesTitlePreference(defaults: defaults).enabled = false

        SettingsReset.resetCapture(config: CaptureConfig(), defaults: defaults)

        XCTAssertTrue(AutoScrollPreference.isEnabled(defaults))
        XCTAssertTrue(SmartRedactionPreference.autoScanEnabled(defaults),
                      "auto-scan lives on the On-Device AI tab; Capture reset must not touch it")
        XCTAssertTrue(FilenameIncludesTitlePreference(defaults: defaults).enabled)
    }

    func test_resetRecording_restoresEveryTabSetting() {
        let p = RecordingPreference(defaults: defaults)
        p.format = .h264Mp4
        p.frameRate = 60
        p.capturesSystemAudio = false
        p.capturesMicrophone = true
        p.reducesMicNoise = false
        p.showsCursor = false
        p.asksBeforeRecording = false

        SettingsReset.resetRecording(defaults: defaults)

        XCTAssertEqual(p.format, .hevcMov)
        XCTAssertEqual(p.frameRate, 30)
        XCTAssertTrue(p.capturesSystemAudio)
        XCTAssertFalse(p.capturesMicrophone)
        XCTAssertTrue(p.reducesMicNoise)
        XCTAssertTrue(p.showsCursor)
        XCTAssertTrue(p.asksBeforeRecording)
    }

    func test_resetAll_coversEveryScope() {
        AIFeaturePreference(defaults: defaults).enabled = false
        AutoScrollPreference.set(false, into: defaults)
        RecordingPreference(defaults: defaults).frameRate = 60

        SettingsReset.resetAll(config: CaptureConfig(), defaults: defaults)

        XCTAssertTrue(AIFeaturePreference(defaults: defaults).enabled)
        XCTAssertTrue(AutoScrollPreference.isEnabled(defaults))
        XCTAssertEqual(RecordingPreference(defaults: defaults).frameRate, 30)
    }

    func test_captureConfig_scopedResets() {
        // The config halves: General owns appearance+saveFolder+retention
        // (the save location directs BOTH captures and recordings, so it
        // lives on the General tab), Capture owns output+filename (asserted
        // via the standard-defaults-backed CaptureConfig, mirroring
        // CaptureConfigSettingsTests' approach).
        let c = CaptureConfig()
        defer { c.resetToDefaults() }

        c.appearancePreference = .dark
        c.retentionDays = 99
        c.saveFolder = FileManager.default.temporaryDirectory
        c.defaultOutput = .clipboard
        c.resetGeneralDefaults()
        XCTAssertEqual(c.appearancePreference, .system)
        XCTAssertEqual(c.retentionDays, CaptureConfig.defaultRetentionDays)
        XCTAssertEqual(c.saveFolder, CaptureConfig.defaultSaveFolder)
        XCTAssertEqual(c.defaultOutput, .clipboard, "General reset must not touch Capture fields")

        c.filenameFormat = "custom"
        c.resetCaptureDefaults()
        XCTAssertEqual(c.defaultOutput, .both)
        XCTAssertEqual(c.filenameFormat, CaptureConfig.defaultFilenameFormat)
    }
}
