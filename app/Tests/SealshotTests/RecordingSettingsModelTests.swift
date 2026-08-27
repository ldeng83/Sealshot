import XCTest
@testable import Sealshot

@MainActor
final class RecordingSettingsModelTests: XCTestCase {
    private func freshPref() -> RecordingPreference {
        RecordingPreference(defaults: UserDefaults(suiteName: "RecSettingsModel-\(UUID().uuidString)")!)
    }

    func test_initReadsPreference() {
        let pref = freshPref()
        pref.capturesMicrophone = true
        pref.countdownSeconds = 5
        let model = RecordingSettingsModel(pref: pref)
        XCTAssertTrue(model.micAudio)
        XCTAssertEqual(model.countdown, 5)
        XCTAssertTrue(model.systemAudio)   // default
    }

    func test_changesPersistToPreference() {
        let pref = freshPref()
        let model = RecordingSettingsModel(pref: pref)
        model.systemAudio = false
        model.countdown = 10
        model.askBefore = false
        XCTAssertFalse(pref.capturesSystemAudio)
        XCTAssertEqual(pref.countdownSeconds, 10)
        XCTAssertFalse(pref.asksBeforeRecording)
    }
}
