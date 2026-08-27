import XCTest
import AppKit
@testable import Sealshot

/// A video tile in the editor strip must show its duration badge ("m:ss")
/// straight from the indexed duration. A `.seal` video package can't be read
/// by AVURLAsset, so relying on the async loader leaves the badge blank — the
/// tile must use the duration threaded in from the index instead.
@MainActor
final class RecentStripDurationTests: XCTestCase {

    private func makeTile(durationSeconds: Double?) -> RecentThumbnailView {
        RecentThumbnailView(
            fileURL: URL(fileURLWithPath: "/does/not/exist/rec.seal", isDirectory: true),
            image: NSImage(),
            displayName: "rec",
            mode: .recent,
            isVideo: true,
            isEncrypted: false,
            durationSeconds: durationSeconds,
            thumbHeight: 90,
            thumbAspect: 4.0 / 3.0,
            frame: NSRect(x: 0, y: 0, width: 120, height: 110))
    }

    func test_videoTile_showsIndexedDurationImmediately() {
        let tile = makeTile(durationSeconds: 83)   // 1:23
        XCTAssertEqual(tile.debugDurationText, "1:23",
                       "the tile must format the indexed duration into its badge")
    }

    private func item(isVideo: Bool, duration: Double?) -> StripItem {
        StripItem(url: URL(fileURLWithPath: "/x/rec.seal", isDirectory: true),
                  captureDate: Date(timeIntervalSince1970: 0),
                  displayName: "rec", isVideo: isVideo, isEncrypted: false,
                  durationSeconds: duration)
    }

    func test_reusedTile_rebuiltWhenVideoClassificationChanges() {
        // A `.seal` first listed before reconcile classified it as a video
        // (encrypted session locked at launch) → an image tile. Once the index
        // catches up, the reused tile must be rebuilt to gain the play/duration.
        XCTAssertTrue(
            RecentStripView.tileNeedsRebuild(tileIsVideo: false, tileDuration: nil,
                                             item: item(isVideo: true, duration: 7.92)))
    }

    func test_reusedTile_rebuiltWhenDurationBackfilled() {
        XCTAssertTrue(
            RecentStripView.tileNeedsRebuild(tileIsVideo: true, tileDuration: nil,
                                             item: item(isVideo: true, duration: 7.92)))
    }

    func test_reusedTile_keptWhenUnchanged() {
        XCTAssertFalse(
            RecentStripView.tileNeedsRebuild(tileIsVideo: true, tileDuration: 7.92,
                                             item: item(isVideo: true, duration: 7.92)))
        XCTAssertFalse(
            RecentStripView.tileNeedsRebuild(tileIsVideo: false, tileDuration: nil,
                                             item: item(isVideo: false, duration: nil)))
    }

    func test_videoTile_withoutIndexedDuration_hasNoSyncBadge() {
        // No index duration and an unreadable .seal URL → nothing to draw
        // synchronously (the async loader can't read the package).
        let tile = makeTile(durationSeconds: nil)
        XCTAssertNil(tile.debugDurationText,
                     "with no indexed duration the tile draws no synchronous badge")
    }
}
