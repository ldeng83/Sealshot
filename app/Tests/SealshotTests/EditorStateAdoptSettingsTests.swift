import XCTest
import AppKit
@testable import Sealshot

/// `adoptCreationSettings(from:)` carries the per-tool creation settings from a
/// previous editor state to a freshly built one, so switching images keeps the
/// user's chosen widths/colors/etc. It deliberately does NOT carry document
/// content (annotations, crop) or the active tool (the swap handles that).
@MainActor
final class EditorStateAdoptSettingsTests: XCTestCase {

    private func makeImage(width: Int = 100, height: Int = 100) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makeState() -> EditorState {
        EditorState(sourceImage: makeImage(), sourceURL: nil)
    }

    func testAdopt_copiesColorsAndOpacity() {
        let old = makeState()
        old.selectedColor = .systemBlue
        old.shapeFillColor = .systemYellow
        old.creationOpacity = 0.4

        let new = makeState()
        new.adoptCreationSettings(from: old)

        XCTAssertEqual(new.selectedColor, .systemBlue)
        XCTAssertEqual(new.shapeFillColor, .systemYellow)
        XCTAssertEqual(new.creationOpacity, 0.4)
    }

    func testAdopt_copiesPerToolStrokeWidths() {
        let old = makeState()
        old.selectedTool = .arrow; old.strokeWidth = 8
        old.selectedTool = .line;  old.strokeWidth = 12

        let new = makeState()
        new.adoptCreationSettings(from: old)

        new.selectedTool = .arrow
        XCTAssertEqual(new.strokeWidth, 8)
        new.selectedTool = .line
        XCTAssertEqual(new.strokeWidth, 12)
    }

    func testAdopt_copiesShapeAndTextSettings() {
        let old = makeState()
        old.shapeCornerRadius = 9
        old.textFontSize = 28
        old.textIsBold = true

        let new = makeState()
        new.adoptCreationSettings(from: old)

        XCTAssertEqual(new.shapeCornerRadius, 9)
        XCTAssertEqual(new.textFontSize, 28)
        XCTAssertTrue(new.textIsBold)
    }

    func testAdopt_copiesBadgeSettings() {
        let old = makeState()
        old.badgeFillColor = .systemGreen
        old.badgeNumberColor = .black
        old.badgeRadius = 24

        let new = makeState()
        new.adoptCreationSettings(from: old)

        XCTAssertEqual(new.badgeFillColor, .systemGreen)
        XCTAssertEqual(new.badgeNumberColor, .black)
        XCTAssertEqual(new.badgeRadius, 24)
    }

    func testAdopt_copiesBlurSettings() {
        let old = makeState()
        old.blurMode = .gaussian
        old.blurStrength = 0.9
        old.blurRegionShape = .ellipse
        old.blurBrushWidth = 70
        old.blurSolidColor = .systemTeal

        let new = makeState()
        new.adoptCreationSettings(from: old)

        XCTAssertEqual(new.blurMode, .gaussian)
        XCTAssertEqual(new.blurStrength, 0.9)
        XCTAssertEqual(new.blurRegionShape, .ellipse)
        XCTAssertEqual(new.blurBrushWidth, 70)
        XCTAssertEqual(new.blurSolidColor, .systemTeal)
    }

    func testAdopt_copiesCropAspectRatio() {
        let old = makeState()
        old.cropAspectRatio = 16.0 / 9.0

        let new = makeState()
        new.adoptCreationSettings(from: old)

        XCTAssertEqual(new.cropAspectRatio, 16.0 / 9.0)
    }

    func testAdopt_doesNotCopyActiveToolOrContent() {
        let old = makeState()
        old.selectedTool = .blur
        old.pendingCrop = CGRect(x: 1, y: 2, width: 3, height: 4)

        let new = makeState()
        new.adoptCreationSettings(from: old)

        XCTAssertEqual(new.selectedTool, .select)   // swap carries the tool, not adopt
        XCTAssertNil(new.pendingCrop)               // content is not carried
    }
}
