import XCTest
import ScreenCaptureKit
@testable import Sealshot

@MainActor
final class RecordingUserStoppedTests: XCTestCase {

    func test_userStoppedError_isTreatedAsNormalStop() {
        // What SCK delivers when the OS-level "Stop" control ends the stream.
        let err = NSError(domain: SCStreamError.errorDomain,
                          code: SCStreamError.Code.userStopped.rawValue)
        XCTAssertTrue(RecordingCoordinator.isUserStopped(err))
    }

    func test_otherSCStreamError_isARealError() {
        let err = NSError(domain: SCStreamError.errorDomain,
                          code: SCStreamError.Code.failedToStart.rawValue)
        XCTAssertFalse(RecordingCoordinator.isUserStopped(err))
    }

    func test_nonSCKError_isARealError() {
        let err = NSError(domain: "com.example.other", code: -3817)  // same code, wrong domain
        XCTAssertFalse(RecordingCoordinator.isUserStopped(err))
    }
}
