import XCTest
@testable import Sealshot

/// The one-session-at-a-time policy: any live capture session or recording
/// blocks new capture/recording starts; a capture session outranks the
/// recording reason in the log line.
final class CaptureBusyGateTests: XCTestCase {

    func testIdle_allowsNewSession() {
        XCTAssertNil(CaptureCoordinator.busyReason(captureSessionActive: false,
                                                   recordingActive: false))
    }

    func testCaptureSession_blocks() {
        XCTAssertEqual(CaptureCoordinator.busyReason(captureSessionActive: true,
                                                     recordingActive: false),
                       .captureSession)
    }

    func testRecording_blocks() {
        XCTAssertEqual(CaptureCoordinator.busyReason(captureSessionActive: false,
                                                     recordingActive: true),
                       .recording)
    }

    func testBoth_reportsCaptureSession() {
        XCTAssertEqual(CaptureCoordinator.busyReason(captureSessionActive: true,
                                                     recordingActive: true),
                       .captureSession)
    }
}
