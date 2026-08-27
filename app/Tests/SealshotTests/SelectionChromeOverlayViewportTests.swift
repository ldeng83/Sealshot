import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class SelectionChromeOverlayViewportTests: XCTestCase {

    private func makeImage(_ width: Int = 300, _ height: Int = 200) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private func makeHierarchy() -> (
        EditorState, EditorCanvasView, EditorCanvasScrollView, SelectionChromeOverlay
    ) {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let canvas = EditorCanvasView(state: state)
        let scroll = EditorCanvasScrollView(state: state, canvas: canvas)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 220))
        scroll.frame = host.bounds
        host.addSubview(scroll)

        let overlay = SelectionChromeOverlay(state: state, canvas: canvas, scroll: scroll)
        overlay.frame = host.bounds
        host.addSubview(overlay)
        scroll.layoutSubtreeIfNeeded()
        return (state, canvas, scroll, overlay)
    }

    func test_viewportRectTracksClipFrameInsteadOfFullHost() {
        let (_, _, scroll, overlay) = makeHierarchy()

        // Model the space claimed by legacy vertical + horizontal scrollers.
        // The overlay remains 320x220, while the visible canvas is smaller.
        scroll.contentView.frame = CGRect(x: 0, y: 17, width: 303, height: 203)

        let viewport = overlay.currentViewportRect()
        XCTAssertEqual(viewport.width, 303, accuracy: 0.001)
        XCTAssertEqual(viewport.height, 203, accuracy: 0.001)
        XCTAssertEqual(viewport, overlay.convert(scroll.contentView.bounds, from: scroll.contentView))
    }

    func test_focusBracketOutsideClipDoesNotClaimScrollbarGutter() {
        let (state, _, scroll, overlay) = makeHierarchy()
        scroll.contentView.frame = CGRect(x: 0, y: 0, width: 303, height: 220)

        let viewport = overlay.currentViewportRect()
        let projected = overlay.currentProjection().screen(fromImage: state.effectiveFocusRect)
        let topRight = CGPoint(x: projected.maxX, y: projected.minY)
        XCTAssertGreaterThan(topRight.x, viewport.maxX,
                             "fixture must put the focus corner in the legacy scroller gutter")
        XCTAssertNil(overlay.hitTest(topRight),
                     "chrome outside the clip viewport must not intercept the scroller gutter")
    }

    func test_focusBracketOutsideHorizontalClipDoesNotClaimScrollbarGutter() {
        let (state, _, scroll, overlay) = makeHierarchy()
        scroll.contentView.frame = CGRect(x: 0, y: 17, width: 320, height: 203)

        let viewport = overlay.currentViewportRect()
        let projected = overlay.currentProjection().screen(fromImage: state.effectiveFocusRect)
        let bottomCenter = CGPoint(x: projected.midX, y: projected.maxY)
        XCTAssertFalse(viewport.contains(bottomCenter),
                       "fixture must put the focus edge in the horizontal scroller gutter")
        XCTAssertNil(overlay.hitTest(bottomCenter),
                     "chrome outside the clip viewport must not intercept the horizontal scroller")
    }

    func test_drawDoesNotPaintIntoScrollbarGutter() throws {
        let (_, _, scroll, overlay) = makeHierarchy()
        scroll.contentView.frame = CGRect(x: 0, y: 0, width: 303, height: 220)
        let viewport = overlay.currentViewportRect()

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(overlay.bounds.width), pixelsHigh: Int(overlay.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(overlay.bounds)
        overlay.draw(overlay.bounds)
        NSGraphicsContext.restoreGraphicsState()

        var maximumAlpha: CGFloat = 0
        // Skip the boundary pixel, where antialiasing of the clip itself is
        // permitted; no chrome may reach the body of the gutter.
        for x in (Int(ceil(viewport.maxX)) + 1)..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                maximumAlpha = max(maximumAlpha, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        XCTAssertEqual(maximumAlpha, 0, accuracy: 0.001,
                       "focus chrome must be clipped before the legacy scroller gutter")
    }

    func test_clipFrameChangeInvalidatesOverlay() {
        let (_, _, scroll, overlay) = makeHierarchy()
        let before = overlay.debugScrollGeometryInvalidationCount

        NotificationCenter.default.post(name: NSView.frameDidChangeNotification,
                                        object: scroll.contentView)

        XCTAssertEqual(overlay.debugScrollGeometryInvalidationCount, before + 1,
                       "showing or hiding a legacy scroller must redraw chrome for the new viewport")
    }

    func test_rebindMovesScrollObservationToNewClipView() {
        let (_, _, oldScroll, overlay) = makeHierarchy()
        let newState = EditorState(sourceImage: makeImage(120, 90), sourceURL: nil)
        let newCanvas = EditorCanvasView(state: newState)
        let newScroll = EditorCanvasScrollView(state: newState, canvas: newCanvas)

        overlay.rebind(state: newState, canvas: newCanvas, scroll: newScroll)
        let before = overlay.debugScrollGeometryInvalidationCount

        NotificationCenter.default.post(name: NSView.frameDidChangeNotification,
                                        object: oldScroll.contentView)
        XCTAssertEqual(overlay.debugScrollGeometryInvalidationCount, before,
                       "the old image's clip observer must be removed during rebind")

        NotificationCenter.default.post(name: NSView.frameDidChangeNotification,
                                        object: newScroll.contentView)
        XCTAssertEqual(overlay.debugScrollGeometryInvalidationCount, before + 1,
                       "the replacement image's clip must drive chrome invalidation")
    }

    func test_projectionMatchesAppKitWhenClipBoundsAndFrameScaleDiffer() {
        let (state, canvas, scroll, overlay) = makeHierarchy()
        let clip = scroll.contentView

        // Legacy scroller layout can leave the clip's frame covering the full
        // host while its document-space bounds reserve a 17pt scroller strip.
        // That is an additional view transform, independent of magnification.
        clip.frame = CGRect(x: 0, y: 0, width: 320, height: 220)
        clip.bounds = CGRect(x: -6, y: -12, width: 320, height: 203)
        XCTAssertNotEqual(clip.frame.height, clip.bounds.height,
                          "fixture must reproduce the legacy vertical view scale")

        let inputs = canvas.chromeProjectionInputs()
        let imagePoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: state.visibleImageSize.width, y: 0),
            CGPoint(x: state.visibleImageSize.width, y: state.visibleImageSize.height),
            CGPoint(x: 0, y: state.visibleImageSize.height),
        ]
        let projection = overlay.currentProjection()

        for imagePoint in imagePoints {
            let canvasPoint = CGPoint(
                x: imagePoint.x * inputs.scale + inputs.drawOrigin.x,
                y: imagePoint.y * inputs.scale + inputs.drawOrigin.y
            )
            let appKitPoint = overlay.convert(canvasPoint, from: canvas)
            let projectedPoint = projection.screen(fromImage: imagePoint)

            XCTAssertEqual(projectedPoint.x, appKitPoint.x, accuracy: 0.001)
            XCTAssertEqual(projectedPoint.y, appKitPoint.y, accuracy: 0.001)
            XCTAssertEqual(projection.image(fromScreen: appKitPoint).x, imagePoint.x, accuracy: 0.001)
            XCTAssertEqual(projection.image(fromScreen: appKitPoint).y, imagePoint.y, accuracy: 0.001)
        }
    }
}

/// Who wins when focus chrome and annotation bodies overlap.
///
/// In Live Capture, window layers are large `.image` annotations covering most
/// of the canvas, so an explicit focus area's brackets land on a layer almost
/// by definition. The body used to swallow them — every grab dragged the layer
/// (hand cursor) and the focus area could not be adjusted at all.
@MainActor
final class SelectionChromeOverlayFocusPriorityTests: XCTestCase {

    private func makeImage(_ width: Int = 300, _ height: Int = 200) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    /// A scene-like state: one image layer covering the whole canvas.
    private func makeSceneLikeHierarchy() -> (EditorState, SelectionChromeOverlay) {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.annotations.append(Annotation(
            geometry: .image(rect: CGRect(x: 0, y: 0, width: 300, height: 200),
                             assetID: "layer"),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0)))
        let canvas = EditorCanvasView(state: state)
        let scroll = EditorCanvasScrollView(state: state, canvas: canvas)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 220))
        scroll.frame = host.bounds
        host.addSubview(scroll)
        let overlay = SelectionChromeOverlay(state: state, canvas: canvas, scroll: scroll)
        overlay.frame = host.bounds
        host.addSubview(overlay)
        scroll.layoutSubtreeIfNeeded()
        return (state, overlay)
    }

    func test_explicitFocusBracket_overALayerBody_isChrome() {
        let (state, overlay) = makeSceneLikeHierarchy()
        state.focusRect = CGRect(x: 100, y: 60, width: 100, height: 80)

        let corner = overlay.currentProjection()
            .screen(fromImage: CGPoint(x: 100, y: 60))
        XCTAssertNotNil(overlay.hitTest(corner),
                        "the bracket must be grabbable even over a window layer")
    }

    /// Only the brackets outrank the body — its interior stays the layer's.
    func test_focusInterior_overALayerBody_staysWithTheLayer() {
        let (state, overlay) = makeSceneLikeHierarchy()
        state.focusRect = CGRect(x: 100, y: 60, width: 100, height: 80)

        let middle = overlay.currentProjection()
            .screen(fromImage: CGPoint(x: 150, y: 100))
        XCTAssertNil(overlay.hitTest(middle),
                     "the focus interior must still select/move the layer under it")
    }

    /// The original rationale is preserved: with NO explicit focus area, the
    /// full-image viewfinder's corner anchors yield to an object body there.
    func test_fullImageViewfinderCorner_overABody_stillYieldsToTheBody() {
        let (state, overlay) = makeSceneLikeHierarchy()
        XCTAssertNil(state.focusRect, "precondition: full-image viewfinder")

        let corner = overlay.currentProjection()
            .screen(fromImage: CGPoint(x: 0, y: 0))
        XCTAssertNil(overlay.hitTest(corner),
                     "an object straddling the canvas corner must stay grabbable")
    }
}
