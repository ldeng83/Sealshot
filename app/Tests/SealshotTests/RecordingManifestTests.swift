import XCTest
@testable import Sealshot

final class RecordingManifestTests: XCTestCase {

    func testMakeRecordingManifest_captureKindAndVideoFields() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let m = RecordingCoordinator.makeRecordingManifest(
            durationSeconds: 42.5,
            frameSize: CGSize(width: 1920, height: 1080),
            hasAudio: true,
            now: now)

        XCTAssertEqual(m.captureKind, .screenRecording)
        XCTAssertEqual(m.version, SealManifest.currentVersion)
        XCTAssertEqual(m.sourceSize.width, 1920)
        XCTAssertEqual(m.sourceSize.height, 1080)
        XCTAssertNil(m.sourceApp)
        XCTAssertEqual(m.video?.durationSeconds, 42.5)
        XCTAssertEqual(m.video?.hasAudio, true)
    }

    func testMakeRecordingManifest_noAudio() {
        let m = RecordingCoordinator.makeRecordingManifest(
            durationSeconds: 10.0,
            frameSize: CGSize(width: 2560, height: 1440),
            hasAudio: false,
            now: Date())

        XCTAssertEqual(m.captureKind, .screenRecording)
        XCTAssertEqual(m.video?.hasAudio, false)
        XCTAssertEqual(m.video?.durationSeconds, 10.0)
        XCTAssertEqual(m.sourceSize.width, 2560)
        XCTAssertEqual(m.sourceSize.height, 1440)
    }

    func testMakeRecordingManifest_roundTripsJSON() throws {
        let m = RecordingCoordinator.makeRecordingManifest(
            durationSeconds: 5.0,
            frameSize: CGSize(width: 1280, height: 720),
            hasAudio: true,
            now: Date())
        let back = try SealManifest.decodeJSON(from: m.encodeJSON())
        XCTAssertEqual(back.captureKind, .screenRecording)
        XCTAssertEqual(back.video?.durationSeconds, 5.0)
        XCTAssertEqual(back.video?.hasAudio, true)
        XCTAssertEqual(back.sourceSize.width, 1280)
        XCTAssertEqual(back.sourceSize.height, 720)
    }
}
