import XCTest
import AppKit
@testable import Sealshot

/// Reproduction: when `state.zoom` changes, the meta row's percentage
/// field must reflect it. Mirrors the runtime path (observation-driven).
@MainActor
final class EditorMetaRowZoomTests: XCTestCase {

    private func makeImage(_ w: Int = 100, _ h: Int = 80) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func settle() async {
        // Let the observation's re-arm Task run.
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    func test_metaRowReflectsZoomChange() async {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let row = EditorMetaRowView(
            state: state,
            onFitWindow: {}, onZoom100: {},
            onFitWidth: {}, onFitHeight: {}, onFocus: {},
            onSetZoom: { _ in }, onZoomIn: {}, onZoomOut: {},
            onTabChange: { _ in }
        )
        XCTAssertEqual(row.debugPercentText, "100%", "initial")

        state.zoom = 0.5
        await settle()
        XCTAssertEqual(row.debugPercentText, "50%", "after first change")

        state.zoom = 0.75
        await settle()
        XCTAssertEqual(row.debugPercentText, "75%", "after second change")
    }

    func test_zoomDisplayOverridePinsAndReleases() async {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let row = EditorMetaRowView(
            state: state,
            onFitWindow: {}, onZoom100: {},
            onFitWidth: {}, onFitHeight: {}, onFocus: {},
            onSetZoom: { _ in }, onZoomIn: {}, onZoomOut: {},
            onTabChange: { _ in }
        )
        // Override pins the display (video mode) …
        row.setZoomDisplayOverride(2.0)
        XCTAssertEqual(row.debugPercentText, "200%")
        // … even when the image state's zoom changes underneath.
        state.zoom = 0.5
        await settle()
        XCTAssertEqual(row.debugPercentText, "200%", "override wins over state.zoom")
        // Clearing the override returns to the state-driven display.
        row.setZoomDisplayOverride(nil)
        XCTAssertEqual(row.debugPercentText, "50%")
    }
}
