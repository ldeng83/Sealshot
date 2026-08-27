import AppKit
import XCTest
@testable import Sealshot

@MainActor
final class FloatingThumbnailDragTests: XCTestCase {

    /// Matches the editor strip's own threshold, so a tile behaves the same in
    /// both places.
    func testThreshold_matchesTheEditorStrip() {
        XCTAssertEqual(FloatingCaptureThumbnailView.dragThreshold, 4)
    }

    func testASmallTwitchDoesNotStartADrag() {
        let tile = FloatingCaptureThumbnailView()
        XCTAssertFalse(tile.exceedsDragThresholdForTesting(
            from: NSPoint(x: 10, y: 10), to: NSPoint(x: 12, y: 11)))
    }

    func testMovingPastTheThresholdStartsADrag() {
        let tile = FloatingCaptureThumbnailView()
        XCTAssertTrue(tile.exceedsDragThresholdForTesting(
            from: NSPoint(x: 10, y: 10), to: NSPoint(x: 16, y: 14)))
    }

    /// A tile with no capture behind it must not try to start a drag.
    func testATileWithNoURLNeverStartsADrag() {
        let tile = FloatingCaptureThumbnailView()
        tile.url = nil
        XCTAssertFalse(tile.canStartDragForTesting)
    }

    // MARK: Writer choice

    /// A plain (non-package) capture drags as its own file URL, exactly as it
    /// does from the editor strip. The promise path drops nothing into Terminal,
    /// the editor canvas, or anything else that reads only public.file-url —
    /// which is why the eager URL is the default and the promise the fallback.
    func testAPlainFileDragsAsAFileURL_notAPromise() {
        let url = URL(fileURLWithPath: "/tmp/floating-drag-\(UUID().uuidString).png")
        let source = CaptureDragPayload.Source(url: url, displayName: "Shot", isVideo: false)
        XCTAssertEqual(FloatingCaptureThumbnailView.writerChoice(for: source),
                       .eagerFile(url))
    }

    /// The choice is the strip's own, not a second opinion: whatever
    /// `requiresPromise` says must decide it.
    func testWriterChoice_fallsBackToAPromiseExactlyWhenTheStripWould() {
        let url = URL(fileURLWithPath: "/tmp/floating-drag-\(UUID().uuidString).seal")
        let source = CaptureDragPayload.Source(url: url, displayName: "Clip", isVideo: true)
        let expected: FloatingCaptureThumbnailView.WriterChoice =
            CaptureDragPayload.requiresPromise(source)
                ? .promise
                : CaptureDragPayload.eagerFileURL(for: source).map { .eagerFile($0) } ?? .promise
        XCTAssertEqual(FloatingCaptureThumbnailView.writerChoice(for: source), expected)
    }

    /// A promise's delegate is held weakly by AppKit, so the tile must hand it
    /// to something that outlives the tile — the controller (see
    /// `FloatingCaptureControllerTests`), never the tile itself.
    func testTheTileHandsItsPromiseLifelineOutwards() {
        final class Lifeline {}
        let tile = FloatingCaptureThumbnailView()
        var handed: [AnyObject] = []
        tile.retainDragLifeline = { handed.append($0) }
        tile.retainDragLifeline?(Lifeline())
        XCTAssertEqual(handed.count, 1)
    }
}
