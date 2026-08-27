import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class RecordingSourceRectTests: XCTestCase {

    func test_primaryDisplay_flipsYToTopLeft() {
        // Primary screen at origin, 1440 tall. A global rect 100pt from the
        // bottom, 200 tall → its top is 1440 - (100+200) = 1140 from the top.
        let global = CGRect(x: 50, y: 100, width: 300, height: 200)
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let local = CaptureCoordinator.displayLocalTopLeftRect(global, screenFrame: screen)
        XCTAssertEqual(local, CGRect(x: 50, y: 1140, width: 300, height: 200))
    }

    func test_secondaryDisplay_subtractsOrigin() {
        // A second display to the right at x=2560. A global rect on it maps to
        // display-local coords (origin subtracted), with Y flipped about its top.
        let global = CGRect(x: 2660, y: 200, width: 400, height: 300)
        let screen = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let local = CaptureCoordinator.displayLocalTopLeftRect(global, screenFrame: screen)
        XCTAssertEqual(local, CGRect(x: 100, y: 580, width: 400, height: 300))  // 1080-(200+300)=580
    }
}
