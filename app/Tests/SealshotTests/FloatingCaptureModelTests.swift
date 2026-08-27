import XCTest
@testable import Sealshot

final class FloatingCaptureModelTests: XCTestCase {

    // MARK: Catalog

    func testCatalog_everyKindHasATitleAndSymbol() {
        for kind in FloatingCaptureKind.allCases {
            XCTAssertFalse(kind.title.isEmpty, "\(kind) has no title")
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind) has no symbol")
        }
    }

    /// The overflow lists these in declaration order, and that order must match
    /// the Capture menu's: the everyday capture, then the variants, then
    /// recording. A reader who knows one menu knows the other.
    func testCatalog_isInMenuOrder() {
        XCTAssertEqual(FloatingCaptureKind.allCases,
                       [.unified, .saveAs, .fullScreen, .delayed,
                        .scrolling, .live, .record, .recordSelection])
    }

    /// Titles and icons come from `MenuBarModel`, so the panel cannot drift
    /// away from the status item and the Capture menu.
    func testCatalog_borrowsTheMenusOwnIcons() {
        for kind in FloatingCaptureKind.allCases {
            XCTAssertEqual(kind.symbolName, MenuBarModel.defaultIcon(for: kind.menuAction))
        }
    }

    func testCatalog_onlyRecordKindsAreRecording() {
        let recording = FloatingCaptureKind.allCases.filter(\.isRecording)
        XCTAssertEqual(Set(recording), [.record, .recordSelection])
    }

    // MARK: Face-button promotion

    /// Smart Capture is the everyday one, so it is what a fresh panel offers.
    func testFaceKind_defaultsToSmartCapture() {
        XCTAssertEqual(FloatingCaptureModel().faceKind, .unified)
    }

    func testPerform_promotesTheKindToTheFace() {
        var model = FloatingCaptureModel()
        model.perform(.scrolling)
        XCTAssertEqual(model.faceKind, .scrolling)
    }

    func testPerform_faceKindAgain_leavesItUnchanged() {
        var model = FloatingCaptureModel()
        model.perform(.record)
        model.perform(.record)
        XCTAssertEqual(model.faceKind, .record)
    }

    // MARK: Count

    func testCount_startsAtZero() {
        XCTAssertEqual(FloatingCaptureModel().count, 0)
    }

    func testCaptureLanded_incrementsTheCount() {
        var model = FloatingCaptureModel()
        model.captureLanded()
        model.captureLanded()
        XCTAssertEqual(model.count, 2)
    }

    func testEditorWasOpened_zeroesTheCount() {
        var model = FloatingCaptureModel()
        model.captureLanded()
        model.captureLanded()
        model.editorWasOpened()
        XCTAssertEqual(model.count, 0)
    }

    func testEditorWasOpened_leavesTheFaceKindAlone() {
        var model = FloatingCaptureModel()
        model.perform(.delayed)
        model.editorWasOpened()
        XCTAssertEqual(model.faceKind, .delayed)
    }

    /// `perform` records intent; only a landed capture counts. A cancelled
    /// selection must not inflate the tally.
    func testPerform_aloneDoesNotIncrementTheCount() {
        var model = FloatingCaptureModel()
        model.perform(.unified)
        XCTAssertEqual(model.count, 0)
    }
}
