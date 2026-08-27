import XCTest
@testable import Sealshot

/// `DeletionUndoHistory` is now just the `.fileEvent` payload types + the
/// kind-aware `liveURL` helper (the stacks/pruning moved to `GlobalUndoStore`,
/// covered by `GlobalUndoStoreTests`). These lock the surviving surface.
final class DeletionUndoHistoryTests: XCTestCase {

    private func item(_ name: String) -> DeletionUndoHistory.Item {
        DeletionUndoHistory.Item(
            trashedURL: URL(fileURLWithPath: "/save/Deleted/\(name)"),
            originalURL: URL(fileURLWithPath: "/save/\(name)"))
    }

    // liveURL names which of an item's two locations must still EXIST for a
    // `.fileEvent` entry to be actionable, per gesture and direction — the
    // basis for `GlobalUndoStore.pruneDeadTop` dropping dead file events.

    func testLiveURL_deletion_undoNeedsTrash_redoNeedsOriginal() {
        let i = item("a.seal")
        XCTAssertEqual(DeletionUndoHistory.liveURL(of: i, kind: .deletion, redo: false), i.trashedURL)
        XCTAssertEqual(DeletionUndoHistory.liveURL(of: i, kind: .deletion, redo: true), i.originalURL)
    }

    func testLiveURL_restoration_undoNeedsOriginal_redoNeedsTrash() {
        let i = item("a.seal")
        XCTAssertEqual(DeletionUndoHistory.liveURL(of: i, kind: .restoration, redo: false), i.originalURL)
        XCTAssertEqual(DeletionUndoHistory.liveURL(of: i, kind: .restoration, redo: true), i.trashedURL)
    }

    func testLiveURL_importAndCapture_mirrorRestoration() {
        let i = item("a.seal")
        for kind in [DeletionUndoHistory.Kind.importation, .capture] {
            XCTAssertEqual(DeletionUndoHistory.liveURL(of: i, kind: kind, redo: false), i.originalURL)
            XCTAssertEqual(DeletionUndoHistory.liveURL(of: i, kind: kind, redo: true), i.trashedURL)
        }
    }

    func testEvent_codableRoundTrip() throws {
        let event = DeletionUndoHistory.Event(items: [item("a.seal"), item("b.seal")],
                                              kind: .restoration, containedOpenFile: true,
                                              at: Date(timeIntervalSince1970: 10))
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(DeletionUndoHistory.Event.self, from: data), event)
    }
}

final class EditorSnapshotTimestampTests: XCTestCase {

    private func makeImage(width: Int = 10, height: Int = 10) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// Histories persisted before the `at` field existed must keep decoding.
    func testLegacySnapshotJSONWithoutTimestampDecodes() throws {
        let json = #"{"annotations":[]}"#.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(EditorSnapshot.self, from: json)
        XCTAssertNil(snapshot.at)
        XCTAssertTrue(snapshot.annotations.isEmpty)
    }

    @MainActor
    func testRecordUndoCheckpointStampsNow() {
        let h = TimelineTestHarness(EditorState(sourceImage: makeImage(), sourceURL: nil))
        let before = Date()
        h.state.recordUndoCheckpoint()
        guard case .edit(_, let snap)? = h.store.topUndo?.kind else { return XCTFail() }
        XCTAssertNotNil(snap.at)
        XCTAssertGreaterThanOrEqual(snap.at!, before)
        XCTAssertLessThanOrEqual(snap.at!, Date())
    }

    @MainActor
    func testUndoStampsTheRedoEntry() {
        let h = TimelineTestHarness(EditorState(sourceImage: makeImage(), sourceURL: nil))
        h.state.recordUndoCheckpoint()
        XCTAssertFalse(h.store.canRedo)
        let before = Date()
        _ = h.undo()
        XCTAssertFalse(h.store.canUndo, "undo stack drained")
        guard case .edit(_, let redoSnap)? = h.store.topRedo?.kind else { return XCTFail() }
        XCTAssertNotNil(redoSnap.at)
        XCTAssertGreaterThanOrEqual(redoSnap.at!, before)
    }
}
