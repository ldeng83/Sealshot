import XCTest
@testable import Sealshot

/// The region AI text actions (Summarize / Extract) OCR: the focus area when
/// set, else the crop, else the whole image — all resolved to source-image space.
final class AIOCRRectTests: XCTestCase {
    private let size = CGSize(width: 100, height: 80)

    func testNoCropNoFocus_fullImage() {
        XCTAssertEqual(EditorState.aiOCRRect(sourceSize: size, croppedRect: nil, focusRect: nil),
                       CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    func testCropOnly_returnsCrop() {
        let crop = CGRect(x: 10, y: 5, width: 40, height: 30)
        XCTAssertEqual(EditorState.aiOCRRect(sourceSize: size, croppedRect: crop, focusRect: nil), crop)
    }

    func testFocusOnly_returnsFocus() {
        let focus = CGRect(x: 8, y: 6, width: 20, height: 10)
        XCTAssertEqual(EditorState.aiOCRRect(sourceSize: size, croppedRect: nil, focusRect: focus), focus)
    }

    func testFocusWithinCrop_offsetIntoSourceSpace() {
        let crop = CGRect(x: 10, y: 5, width: 40, height: 30)
        let focus = CGRect(x: 4, y: 3, width: 12, height: 8)   // visible (post-crop) space
        XCTAssertEqual(EditorState.aiOCRRect(sourceSize: size, croppedRect: crop, focusRect: focus),
                       CGRect(x: 14, y: 8, width: 12, height: 8))
    }
}
