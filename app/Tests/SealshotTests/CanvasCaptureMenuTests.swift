import XCTest
import AppKit
@testable import Sealshot

/// The empty-area right-click menu — the actions that act on the open CAPTURE
/// FILE rather than on an object. It mirrors the strip thumbnail menu, so the
/// export group sits with Show in Finder / Show in Library and the video
/// export is omitted entirely (not greyed) for a still capture.
@MainActor
final class CanvasCaptureMenuTests: XCTestCase {

    private func makeImage(width: Int = 400, height: Int = 300) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makeCanvas(sourceURL: URL?) -> (EditorCanvasView, EditorState) {
        let state = EditorState(sourceImage: makeImage(), sourceURL: sourceURL)
        let canvas = EditorCanvasView(state: state)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        return (canvas, state)
    }

    private func savedCanvas() -> (EditorCanvasView, EditorState) {
        makeCanvas(sourceURL: URL(fileURLWithPath: "/tmp/capture-menu-test.seal",
                                  isDirectory: true))
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    // MARK: - The export group

    func testStillCaptureOffersImageAndPackageButNotVideo() {
        let (canvas, _) = savedCanvas()
        canvas.isVideoCapture = { false }

        let menu = try! XCTUnwrap(canvas.captureMenu())
        let items = titles(menu)

        XCTAssertTrue(items.contains("Export to Image"))
        XCTAssertTrue(items.contains("Export to Package…"))
        XCTAssertFalse(items.contains("Export to Video…"),
                       "a still capture has no video to export — omit, don't grey")
    }

    func testVideoCaptureAlsoOffersVideoExport() {
        let (canvas, _) = savedCanvas()
        canvas.isVideoCapture = { true }

        let menu = try! XCTUnwrap(canvas.captureMenu())

        XCTAssertTrue(titles(menu).contains("Export to Video…"))
    }

    /// The export group belongs with the other whole-capture actions, in the
    /// same order the strip thumbnail menu uses — the two menus should read
    /// alike.
    func testExportGroupFollowsShowInLibraryInStripOrder() {
        let (canvas, _) = savedCanvas()
        canvas.isVideoCapture = { true }

        let items = titles(try! XCTUnwrap(canvas.captureMenu()))
        let finder = try! XCTUnwrap(items.firstIndex(of: "Show in Finder"))
        let library = try! XCTUnwrap(items.firstIndex(of: "Show in Library"))
        let image = try! XCTUnwrap(items.firstIndex(of: "Export to Image"))
        let video = try! XCTUnwrap(items.firstIndex(of: "Export to Video…"))
        let package = try! XCTUnwrap(items.firstIndex(of: "Export to Package…"))

        XCTAssertEqual([library, image, video, package], [finder + 1, finder + 2, finder + 3, finder + 4],
                       "Finder, Library, Image, Video, Package must be contiguous and in that order")
    }

    /// Nothing to export before the canvas has been saved: the menu stops after
    /// the background-fill item.
    func testUnsavedCanvasOffersNoCaptureActions() {
        let (canvas, _) = makeCanvas(sourceURL: nil)
        canvas.isVideoCapture = { true }

        let items = titles(try! XCTUnwrap(canvas.captureMenu()))

        XCTAssertFalse(items.contains("Export to Image"))
        XCTAssertFalse(items.contains("Export to Video…"))
        XCTAssertFalse(items.contains("Export to Package…"))
        XCTAssertFalse(items.contains("Show in Finder"))
    }

    /// A missing predicate must not silently advertise a video export.
    func testUnwiredVideoPredicateHidesTheVideoExport() {
        let (canvas, _) = savedCanvas()

        let items = titles(try! XCTUnwrap(canvas.captureMenu()))

        XCTAssertFalse(items.contains("Export to Video…"))
        XCTAssertTrue(items.contains("Export to Image"), "the rest of the group still shows")
    }

    // MARK: - Wiring

    func testExportItemsFireTheCaptureExportHook() {
        let (canvas, state) = savedCanvas()
        canvas.isVideoCapture = { true }
        var fired: [(URL, EditorCanvasView.CaptureExportKind)] = []
        canvas.onExportCapture = { fired.append(($0, $1)) }

        let menu = try! XCTUnwrap(canvas.captureMenu())
        for title in ["Export to Image", "Export to Video…", "Export to Package…"] {
            let item = try! XCTUnwrap(menu.items.first { $0.title == title })
            _ = item.target?.perform(item.action, with: item)
        }

        XCTAssertEqual(fired.map(\.1), [.image, .video, .package])
        XCTAssertEqual(Set(fired.map(\.0)), [state.sourceURL!])
    }
}
