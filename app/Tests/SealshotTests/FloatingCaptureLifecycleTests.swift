import XCTest
@testable import Sealshot

final class FloatingCaptureLifecycleTests: XCTestCase {

    func testRestoreAtLaunch_followsWhatWasOpenAtQuit() {
        XCTAssertTrue(FloatingCaptureLifecycle.shouldRestoreAtLaunch(wasOpenAtQuit: true))
        XCTAssertFalse(FloatingCaptureLifecycle.shouldRestoreAtLaunch(wasOpenAtQuit: false))
    }

}
