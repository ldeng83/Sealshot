import XCTest
@testable import Sealshot

final class RecordingPermissionTests: XCTestCase {
    func test_micOff_requiresOnlyScreen() {
        XCTAssertEqual(RecordingPermission.required(micEnabled: false), [.screenRecording])
    }
    func test_micOn_requiresScreenAndMic() {
        XCTAssertEqual(Set(RecordingPermission.required(micEnabled: true)),
                       Set([.screenRecording, .microphone]))
    }
}
