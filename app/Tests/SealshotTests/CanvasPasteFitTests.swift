import XCTest
import AppKit
@testable import Sealshot

/// Pasting an image bigger than the canvas.
///
/// On the empty surface File ▸ New Canvas hands you there is nothing to
/// preserve, so the canvas grows to the image — the same result ⇧⌘N (New from
/// Clipboard) gives, reached by the route people actually take. On a capture
/// the canvas IS the content, so the image is scaled onto it as before.
@MainActor
final class CanvasPasteFitTests: XCTestCase {

    private func image(_ w: Int, _ h: Int, opaque: Bool) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if opaque {
            ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        }
        return ctx.makeImage()!
    }

    private func makeController(source: CGImage) -> EditorWindowController {
        let config = CaptureConfig()
        return EditorWindowController(
            state: EditorState(sourceImage: source, sourceURL: nil),
            saver: EditorSaveCoordinator(config: config),
            config: config,
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            title: "paste",
            onRecentClick: { _ in }
        )
    }

    /// Put a real image on a scratch pasteboard and paste it as the user
    /// would — through the window's own paste command.
    private func paste(_ img: CGImage, into controller: EditorWindowController) throws {
        let rep = NSBitmapImageRep(cgImage: img)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
        // The paste path requires the canvas to hold focus, exactly as it does
        // in the app — otherwise a paste meant for a text field would be stolen.
        let canvas = try XCTUnwrap(controller.debugCanvasView)
        controller.window?.makeFirstResponder(canvas)
        XCTAssertTrue(controller.debugPaste(), "the paste should be handled")
    }

    /// The reported bug: a blank canvas kept its 800×500 and shrank the image.
    func testPastingIntoABlankCanvas_growsTheCanvasToTheImage() throws {
        let controller = makeController(source: image(800, 500, opaque: false))
        let state = try XCTUnwrap(controller.debugState)
        XCTAssertEqual(state.visibleImageSize, CGSize(width: 800, height: 500))

        try paste(image(1600, 1200, opaque: true), into: controller)

        XCTAssertEqual(state.visibleImageSize, CGSize(width: 1600, height: 1200),
                       "the canvas should have grown to fit the pasted image")
        // And at full resolution — growing the canvas around a downscaled copy
        // would be worse than not growing at all.
        guard case let .image(rect, assetID)? = state.annotations.first?.geometry else {
            return XCTFail("expected one image annotation")
        }
        XCTAssertEqual(rect.size, CGSize(width: 1600, height: 1200))
        let stored = try XCTUnwrap(state.assetImage(assetID))
        XCTAssertEqual(stored.width, 1600)
        XCTAssertEqual(stored.height, 1200)
    }

    /// An image that already fits changes nothing about the canvas.
    func testPastingASmallImage_leavesTheCanvasAlone() throws {
        let controller = makeController(source: image(800, 500, opaque: false))
        let state = try XCTUnwrap(controller.debugState)

        try paste(image(200, 150, opaque: true), into: controller)

        XCTAssertEqual(state.visibleImageSize, CGSize(width: 800, height: 500))
        XCTAssertEqual(state.annotations.count, 1)
    }

    /// A capture must never be grown to wrap a pasted photo in transparent
    /// margin: there the canvas is the content, and the image is an overlay.
    func testPastingOntoACapture_scalesTheImageInsteadOfGrowing() throws {
        let controller = makeController(source: image(800, 500, opaque: true))
        let state = try XCTUnwrap(controller.debugState)

        try paste(image(1600, 1200, opaque: true), into: controller)

        XCTAssertEqual(state.visibleImageSize, CGSize(width: 800, height: 500),
                       "a screenshot keeps its size")
        guard case let .image(rect, _)? = state.annotations.first?.geometry else {
            return XCTFail("expected one image annotation")
        }
        XCTAssertLessThanOrEqual(rect.width, 800)
        XCTAssertLessThanOrEqual(rect.height, 500)
    }

    /// The case the first fix MISSED, caught in the field by the undo log
    /// naming the checkpoint 'Paste' rather than 'Insert Image': copying from
    /// another Sealshot capture puts the app's OWN payload on the clipboard,
    /// which `pasteAnnotations` consumes before the raw-image path is ever
    /// reached. Content copied from a capture routinely dwarfs an 800×500
    /// canvas, so this is the common route, not the exotic one.
    func testPastingSealshotsOwnPayload_alsoGrowsABlankCanvas() throws {
        let controller = makeController(source: image(800, 500, opaque: false))
        let state = try XCTUnwrap(controller.debugState)

        // A copied image annotation, sized as it was in the capture it came from.
        let copied = image(1400, 900, opaque: true)
        let assetID = UUID().uuidString
        let png = try XCTUnwrap(try? CaptureOutputWriter.encodePNG(copied))
        let annotation = Annotation(
            geometry: .image(rect: CGRect(x: 0, y: 0, width: 1400, height: 900),
                             assetID: assetID),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0,
                         opacity: 1.0))
        AnnotationPasteboard.write(
            AnnotationClipboardPayload(annotations: [annotation], assets: [assetID: png]))

        let canvas = try XCTUnwrap(controller.debugCanvasView)
        controller.window?.makeFirstResponder(canvas)
        XCTAssertTrue(controller.debugPaste())

        XCTAssertGreaterThanOrEqual(state.visibleImageSize.width, 1400,
                                    "the canvas should have grown to the pasted content")
        XCTAssertGreaterThanOrEqual(state.visibleImageSize.height, 900)
    }

    /// The same payload onto a CAPTURE leaves the capture's size alone.
    func testPastingSealshotsOwnPayloadOntoACapture_doesNotGrow() throws {
        let controller = makeController(source: image(800, 500, opaque: true))
        let state = try XCTUnwrap(controller.debugState)

        let copied = image(1400, 900, opaque: true)
        let assetID = UUID().uuidString
        let png = try XCTUnwrap(try? CaptureOutputWriter.encodePNG(copied))
        let annotation = Annotation(
            geometry: .image(rect: CGRect(x: 0, y: 0, width: 1400, height: 900),
                             assetID: assetID),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0,
                         opacity: 1.0))
        AnnotationPasteboard.write(
            AnnotationClipboardPayload(annotations: [annotation], assets: [assetID: png]))

        let canvas = try XCTUnwrap(controller.debugCanvasView)
        controller.window?.makeFirstResponder(canvas)
        XCTAssertTrue(controller.debugPaste())

        XCTAssertEqual(state.visibleImageSize, CGSize(width: 800, height: 500))
    }

    /// Once something is on the surface, a paste stops resizing it — growing
    /// would move the ground under work already done.
    func testPastingWhenTheCanvasAlreadyHasContent_doesNotGrow() throws {
        let controller = makeController(source: image(800, 500, opaque: false))
        let state = try XCTUnwrap(controller.debugState)
        state.insertImageAnnotation(image(100, 100, opaque: true), at: nil)
        XCTAssertEqual(state.annotations.count, 1)

        try paste(image(1600, 1200, opaque: true), into: controller)

        XCTAssertEqual(state.visibleImageSize, CGSize(width: 800, height: 500))
        XCTAssertEqual(state.annotations.count, 2)
    }
}
