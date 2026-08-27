import XCTest
import AppKit
import CoreGraphics
@testable import Sealshot

/// Verifies that the clipboard copy (⌘C / Copy All) emits ONLY the focus-crop
/// area when a `focusRect` is set. The export path (⌘S / SealExporter) shares
/// the same `render(focus:)` call, so this also covers it.
@MainActor
final class EditorCopyExportFocusTests: XCTestCase {

    private func solidImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    func testCopyEmitsFocusAreaOnly() throws {
        let saver = EditorSaveCoordinator(config: CaptureConfig())
        let state = EditorState(sourceImage: solidImage(100, 80), sourceURL: nil)
        state.focusRect = CGRect(x: 10, y: 10, width: 40, height: 30)

        NSPasteboard.general.clearContents()
        try saver.copy(state: state)

        let data = try XCTUnwrap(NSPasteboard.general.data(forType: .png),
                                 "no PNG on the clipboard after copy")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 40, "copy should be cropped to the focus width")
        XCTAssertEqual(rep.pixelsHigh, 30, "copy should be cropped to the focus height")
    }

    func testCopyWithoutFocusEmitsFullImage() throws {
        let saver = EditorSaveCoordinator(config: CaptureConfig())
        let state = EditorState(sourceImage: solidImage(100, 80), sourceURL: nil)
        // focusRect == nil

        NSPasteboard.general.clearContents()
        try saver.copy(state: state)

        let data = try XCTUnwrap(NSPasteboard.general.data(forType: .png))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 100)
        XCTAssertEqual(rep.pixelsHigh, 80)
    }
}
