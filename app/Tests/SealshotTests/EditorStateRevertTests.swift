import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class EditorStateRevertTests: XCTestCase {
    private func img(_ w: Int, _ h: Int) -> CGImage {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    func test_revertedToOriginal_targetsPristineAndDefaultsEverything() {
        // A resized state (sourceImage is resampled; pristineSource is the original)
        // with a full spread of edits.
        let pristine = img(20, 20)
        let s = EditorState(sourceImage: img(40, 40), sourceURL: nil,
                            enhancedImage: img(80, 80), showingEnhanced: true,
                            pristineSource: pristine)
        s.annotations = [Annotation(geometry: .rectangle(rect: .init(x: 1, y: 1, width: 2, height: 2)),
                                    style: Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1), strokeWidth: 2))]
        s.croppedRect = CGRect(x: 0, y: 0, width: 5, height: 5)
        s.focusRect = CGRect(x: 0, y: 0, width: 3, height: 3)
        s.backgroundFill = SerializableColor(r: 0, g: 0, b: 0, a: 1)
        s.cutoutImage = img(40, 40); s.showingCutout = true
        s.imageAssets = ["k": Data([1, 2, 3])]

        let r = s.revertedToOriginal()

        XCTAssertTrue(r.sourceImage === s.persistedSourceImage, "reverted base is the pristine image")
        XCTAssertEqual(r.sourceImage.width, 20)
        XCTAssertTrue(r.annotations.isEmpty)
        XCTAssertNil(r.croppedRect)
        XCTAssertNil(r.focusRect)
        XCTAssertNil(r.backgroundFill)
        XCTAssertNil(r.enhancedImage)
        XCTAssertFalse(r.showingEnhanced)
        XCTAssertNil(r.cutoutImage)
        XCTAssertFalse(r.showingCutout)
        XCTAssertNil(r.pristineSource)
        XCTAssertNil(r.resizedSize)
        // Asset BYTES survive revert on purpose, even though the annotations
        // referencing them are dropped: assets are never pruned, so the
        // autosave after a revert must not strip asset-*.png from the package
        // (a scene that loses its layer annotations stays pixel-recoverable).
        // Asserting these are empty is the data-loss bug 24bbec9f fixed.
        XCTAssertEqual(r.imageAssets, s.imageAssets, "revert must carry asset bytes forward")
        XCTAssertTrue(r.isDirty)
    }

    func test_revertedToOriginal_preservesCreationSettings() {
        let s = EditorState(sourceImage: img(20, 20), sourceURL: nil)
        s.selectedColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        s.textFontSize = 42
        let r = s.revertedToOriginal()
        XCTAssertEqual(r.selectedColor, s.selectedColor)
        XCTAssertEqual(r.textFontSize, 42)
    }
}
