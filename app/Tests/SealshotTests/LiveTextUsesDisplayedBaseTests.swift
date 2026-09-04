import XCTest
import AppKit
@testable import Sealshot

/// Live Text reads the base that is on screen — nothing more.
///
/// It used to run an "auto-enhance session": picking the tool turned Enhance
/// Clarity ON for its duration and, on a capture with no enhanced image,
/// probed for text and then ran the full super-resolution pipeline to make one.
/// That generated image outlived the session — every save writes
/// `state.enhancedImage`, so `enhanced.png` landed in the `.seal` package of a
/// capture whose manifest still said `showingEnhanced: false`. Enhance Clarity
/// is the user's switch: Live Text honours it, and never flips it.
@MainActor
final class LiveTextUsesDisplayedBaseTests: XCTestCase {

    private func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func makeController(_ state: EditorState) -> EditorWindowController {
        let config = CaptureConfig()
        return EditorWindowController(
            state: state,
            saver: EditorSaveCoordinator(config: config),
            config: config,
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            title: "live text",
            onRecentClick: { _ in })
    }

    /// Enhance Clarity ON: the enhanced pixels are what the user sees, so they
    /// are what gets recognized.
    func test_enhanceClarityOn_ocrsTheEnhancedBase() throws {
        let source = image(400, 300)
        let enhanced = image(800, 600)
        let state = EditorState(sourceImage: source, sourceURL: nil,
                                enhancedImage: enhanced, showingEnhanced: true)
        let controller = makeController(state)
        let canvas = try XCTUnwrap(controller.debugCanvasView)

        XCTAssertTrue(canvas.debugOCRInputImage === enhanced)
    }

    /// Enhance Clarity OFF with an enhanced image already cached: Live Text
    /// must NOT reach for it. The old session flipped the switch on here.
    func test_enhanceClarityOff_ocrsThePlainBase_evenWithACachedEnhancedImage() throws {
        let source = image(400, 300)
        let enhanced = image(800, 600)
        let state = EditorState(sourceImage: source, sourceURL: nil,
                                enhancedImage: enhanced, showingEnhanced: false)
        let controller = makeController(state)
        let canvas = try XCTUnwrap(controller.debugCanvasView)

        state.userSelectedTool(.textSelect)

        XCTAssertFalse(state.showingEnhanced, "picking Live Text must not turn Enhance Clarity on")
        XCTAssertTrue(canvas.debugOCRInputImage === source)
    }

    /// Enhance Clarity OFF with no enhanced image: picking the tool must not
    /// manufacture one. Generating it wrote a 2x PNG into the user's package.
    func test_selectingLiveText_doesNotGenerateAnEnhancedImage() throws {
        let source = image(400, 300)
        let state = EditorState(sourceImage: source, sourceURL: nil)
        let controller = makeController(state)
        let canvas = try XCTUnwrap(controller.debugCanvasView)

        state.userSelectedTool(.textSelect)

        XCTAssertNil(state.enhancedImage, "no enhancement is started on the user's behalf")
        XCTAssertFalse(state.showingEnhanced)
        XCTAssertTrue(canvas.debugOCRInputImage === source)
    }

    /// Leaving the tool has nothing to restore, so the user's choice simply
    /// stands — including a capture they had explicitly enhanced.
    func test_leavingLiveText_leavesTheUsersChoiceAlone() throws {
        let state = EditorState(sourceImage: image(400, 300), sourceURL: nil,
                                enhancedImage: image(800, 600), showingEnhanced: true)
        _ = makeController(state)

        state.userSelectedTool(.textSelect)
        state.userSelectedTool(.select)

        XCTAssertTrue(state.showingEnhanced, "the user's enhanced view survives the tool")
    }

    /// A save records what the user chose. With no session there is no
    /// temporary flip to hide, so the persisted value simply follows.
    func test_persistedShowingEnhanced_followsTheLiveValue() {
        let state = EditorState(sourceImage: image(400, 300), sourceURL: nil,
                                enhancedImage: image(800, 600), showingEnhanced: false)
        state.selectedTool = .textSelect
        XCTAssertFalse(state.persistedShowingEnhanced)
        state.showingEnhanced = true
        XCTAssertTrue(state.persistedShowingEnhanced)
    }
}
