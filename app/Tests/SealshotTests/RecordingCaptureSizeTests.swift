import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class RecordingCaptureSizeTests: XCTestCase {

    func test_retinaScale_doublesToNativePixels() {
        // A 1470×956 logical display at 2× must record at native 2940×1912.
        let px = ScreenRecorder.pixelSize(points: CGSize(width: 1470, height: 956), scale: 2)
        XCTAssertEqual(px, CGSize(width: 2940, height: 1912))
    }

    func test_nonRetina_unchanged() {
        let px = ScreenRecorder.pixelSize(points: CGSize(width: 1920, height: 1080), scale: 1)
        XCTAssertEqual(px, CGSize(width: 1920, height: 1080))
    }

    func test_fractionalScale_roundsToWholePixels() {
        let px = ScreenRecorder.pixelSize(points: CGSize(width: 1000, height: 600), scale: 1.5)
        XCTAssertEqual(px, CGSize(width: 1500, height: 900))
    }
}
