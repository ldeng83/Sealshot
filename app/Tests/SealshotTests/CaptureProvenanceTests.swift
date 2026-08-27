import XCTest
@testable import Sealshot

final class CaptureProvenanceTests: XCTestCase {
    func testCaptureKindLabels() {
        XCTAssertEqual(CaptureKind.screenshot.displayLabel, "Screenshot")
        XCTAssertEqual(CaptureKind.importedImage.displayLabel, "Imported image")
        XCTAssertEqual(CaptureKind.clipboard.displayLabel, "Clipboard")
        XCTAssertEqual(CaptureKind.newCanvas.displayLabel, "New canvas")
        XCTAssertEqual(CaptureKind.screenRecording.displayLabel, "Screen recording")
        XCTAssertEqual(CaptureKind.importedVideo.displayLabel, "Imported video")
    }
    func testCaptureModeLabels() {
        XCTAssertEqual(CaptureMode.area.displayLabel, "Area")
        XCTAssertEqual(CaptureMode.window.displayLabel, "Window")
        XCTAssertEqual(CaptureMode.fullScreen.displayLabel, "Full screen")
        XCTAssertEqual(CaptureMode.scrolling.displayLabel, "Scrolling")
    }
    func testRawValuesStableForPersistence() {
        XCTAssertEqual(CaptureKind.importedImage.rawValue, "importedImage")
        XCTAssertEqual(CaptureMode.fullScreen.rawValue, "fullScreen")
    }
}
