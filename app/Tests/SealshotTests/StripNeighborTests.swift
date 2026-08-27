import XCTest
@testable import Sealshot

/// `stripNeighbor` decides which item the editor moves to after the
/// currently-open file is deleted from the strip. It follows the strip's
/// VISIBLE order (the list passed in) and lands on the item immediately to the
/// right — whatever its type (image or video) — never a re-derived "random"
/// pick. See the post-delete-fallback in `performBulkDelete`.
final class StripNeighborTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/shots/\(name)")
    }

    func test_picksFileImmediatelyToTheRight() {
        let order = [url("a.seal"), url("b.seal"), url("c.seal")]
        XCTAssertEqual(
            stripNeighbor(after: url("a.seal"), excluding: [url("a.seal")], in: order),
            url("b.seal"))
    }

    func test_picksNextRegardlessOfType_video() {
        // The next item to the right is a recording — fall back to it anyway
        // (the caller plays it); don't skip to the next image.
        let order = [url("a.seal"), url("clip.mov"), url("b.seal")]
        XCTAssertEqual(
            stripNeighbor(after: url("a.seal"), excluding: [url("a.seal")], in: order),
            url("clip.mov"))
    }

    func test_picksNextRegardlessOfType_encryptedRecording() {
        let order = [url("a.seal"), url("clip.sealrec"), url("b.seal")]
        XCTAssertEqual(
            stripNeighbor(after: url("a.seal"), excluding: [url("a.seal")], in: order),
            url("clip.sealrec"))
    }

    func test_skipsOtherBatchMembersToTheRight() {
        let order = [url("a.seal"), url("b.seal"), url("c.seal"), url("d.seal")]
        let batch: Set<URL> = [url("a.seal"), url("b.seal")]
        XCTAssertEqual(
            stripNeighbor(after: url("a.seal"), excluding: batch, in: order),
            url("c.seal"))
    }

    func test_atRightEnd_fallsBackToNearestLeftRegardlessOfType() {
        // Deleting the rightmost (oldest) open file: walk left for the new
        // rightmost — which may be a video.
        let order = [url("a.seal"), url("clip.mov"), url("c.seal")]
        XCTAssertEqual(
            stripNeighbor(after: url("c.seal"), excluding: [url("c.seal")], in: order),
            url("clip.mov"))
    }

    func test_removedNotInList_returnsFirstRemaining() {
        let order = [url("clip.mov"), url("a.seal"), url("b.seal")]
        XCTAssertEqual(
            stripNeighbor(after: url("gone.seal"), excluding: [url("gone.seal")], in: order),
            url("clip.mov"))
    }

    func test_nothingRemainsOutsideBatch_returnsNil() {
        let order = [url("a.seal"), url("b.seal")]
        XCTAssertNil(
            stripNeighbor(after: url("a.seal"), excluding: [url("a.seal"), url("b.seal")], in: order))
    }

    func test_followsVisibleOrder_notDateOrFilesystemOrder() {
        // The whole point of the fix: the neighbor is defined by the order the
        // user SEES, not an independently re-derived listing. Here the visible
        // order is reversed relative to filename — the neighbor follows what's
        // passed in.
        let order = [url("c.seal"), url("b.seal"), url("a.seal")]
        XCTAssertEqual(
            stripNeighbor(after: url("c.seal"), excluding: [url("c.seal")], in: order),
            url("b.seal"))
    }
}
