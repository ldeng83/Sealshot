import XCTest
@testable import Sealshot

final class RecordingPreferenceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "rec-pref-\(name.replacingOccurrences(of: " ", with: "_"))"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
    func test_defaults() {
        let p = RecordingPreference(defaults: freshDefaults())
        XCTAssertEqual(p.format, .hevcMov)
        XCTAssertEqual(p.frameRate, 30)
        XCTAssertTrue(p.capturesSystemAudio)
        XCTAssertFalse(p.capturesMicrophone)
        XCTAssertTrue(p.showsCursor)
        XCTAssertEqual(p.countdownSeconds, 3)   // 3s pre-roll by default
        XCTAssertTrue(p.asksBeforeRecording)    // prompt shown by default
    }
    func test_persists() {
        let d = freshDefaults()
        let p = RecordingPreference(defaults: d)
        p.format = .h264Mp4
        p.frameRate = 60
        p.capturesMicrophone = true
        XCTAssertEqual(RecordingPreference(defaults: d).format, .h264Mp4)
        XCTAssertEqual(RecordingPreference(defaults: d).frameRate, 60)
        XCTAssertTrue(RecordingPreference(defaults: d).capturesMicrophone)
    }
    func test_reducesMicNoise_defaultsTrue() {
        let d = UserDefaults(suiteName: "test.micnoise.\(UUID().uuidString)")!
        XCTAssertTrue(RecordingPreference(defaults: d).reducesMicNoise)
    }
    func test_reducesMicNoise_persists() {
        let d = UserDefaults(suiteName: "test.micnoise.\(UUID().uuidString)")!
        RecordingPreference(defaults: d).reducesMicNoise = false
        XCTAssertFalse(RecordingPreference(defaults: d).reducesMicNoise)
    }
}
