import XCTest
import AppKit
@testable import Sealshot

/// The Blur tool's properties panel adapts to its own sub-settings: the brush
/// width control is only relevant to the freehand brush, and the intensity
/// slider means "opacity" for a solid block-out but "strength" for the sampling
/// effects (pixelate/mosaic/gaussian).
@MainActor
final class BlurPropertiesPanelTests: XCTestCase {

    private func image(_ w: Int = 80, _ h: Int = 60) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// All section-header titles in the panel (uppercased, as rendered).
    private func headerTitles(_ view: NSView) -> [String] {
        var out: [String] = []
        for sub in view.subviews {
            if let h = sub as? SidebarSectionHeader { out.append(h.stringValue) }
            out.append(contentsOf: headerTitles(sub))
        }
        return out
    }

    private func blurPanelTitles(_ state: EditorState) -> [String] {
        let panel = EditorToolPropertiesViews.make(
            for: .blur, state: state,
            onCommitCrop: {}, onCopySelectedText: {}, onCopyAllText: {})
        return headerTitles(panel)
    }

    func test_brushWidth_shownOnlyForFreehandShape() {
        let state = EditorState(sourceImage: image(), sourceURL: nil)

        state.blurRegionShape = .freehand
        XCTAssertTrue(blurPanelTitles(state).contains { $0.contains("BRUSH WIDTH") })

        state.blurRegionShape = .rect
        XCTAssertFalse(blurPanelTitles(state).contains { $0.contains("BRUSH WIDTH") })

        state.blurRegionShape = .ellipse
        XCTAssertFalse(blurPanelTitles(state).contains { $0.contains("BRUSH WIDTH") })
    }

    func test_intensityLabel_isOpacityForSolid_strengthOtherwise() {
        let state = EditorState(sourceImage: image(), sourceURL: nil)

        state.blurMode = .gaussian
        let gaussian = blurPanelTitles(state)
        XCTAssertTrue(gaussian.contains("STRENGTH"))
        XCTAssertFalse(gaussian.contains("OPACITY"))

        state.blurMode = .solid
        let solid = blurPanelTitles(state)
        XCTAssertTrue(solid.contains("OPACITY"))
        XCTAssertFalse(solid.contains("STRENGTH"))
    }

    func test_solidColor_shownOnlyForSolidEffect() {
        let state = EditorState(sourceImage: image(), sourceURL: nil)

        state.blurMode = .solid
        XCTAssertTrue(blurPanelTitles(state).contains("SOLID COLOR"))

        state.blurMode = .gaussian
        XCTAssertFalse(blurPanelTitles(state).contains("SOLID COLOR"))
    }
}
