import XCTest
import AppKit
@testable import Sealshot

/// The undo/redo unification: size-aware snapshots (⌘Z across Resize),
/// enhanced-flag restore, and file events on the app-global timeline. Drives
/// the state through `TimelineTestHarness` (mirroring the controller) now that
/// the per-image stacks are retired in favour of `GlobalUndoStore`.
@MainActor
final class UndoUnificationTests: XCTestCase {

    private func img(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    // MARK: size-aware snapshots

    func test_snapshot_sameSize_restoresInPlace() {
        let state = EditorState(sourceImage: img(200, 100), sourceURL: nil)
        let snap = state.makeSnapshot(action: "Add Arrow")
        XCTAssertFalse(state.snapshotRequiresRebuild(snap),
                       "same-size snapshot restores in place")
    }

    func test_snapshotRequiresRebuild_whenSnapshotSizeDiffers() {
        // A snapshot minted at 200×100, examined against a 100×50 document
        // (what a post-resize state sees when it reaches this timeline entry).
        let original = EditorState(sourceImage: img(200, 100), sourceURL: nil)
        let snap = original.makeSnapshot(action: "Resize to 100 × 50")
        let resized = EditorState(sourceImage: img(100, 50), sourceURL: nil,
                                  pristineSource: img(200, 100))
        XCTAssertTrue(resized.snapshotRequiresRebuild(snap),
                      "snapshot lives in the 200×100 space — needs the rebuild path")
    }

    func test_legacySnapshot_decodesWithoutNewFields() throws {
        let json = #"{"annotations":[],"croppedRect":null,"focusRect":null,"sourceURL":null}"#
        let snap = try JSONDecoder().decode(EditorSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.sourceImageSize)
        XCTAssertNil(snap.showingEnhanced)
    }

    // MARK: enhanced flag restore

    func test_undo_restoresEnhancedToggle() {
        let h = TimelineTestHarness(EditorState(sourceImage: img(100, 50), sourceURL: nil,
                                                enhancedImage: img(200, 100), showingEnhanced: false))
        h.state.recordUndoCheckpoint(action: "Show Enhanced")
        h.state.showingEnhanced = true
        _ = h.undo()
        XCTAssertFalse(h.state.showingEnhanced)
        _ = h.redo()
        XCTAssertTrue(h.state.showingEnhanced)
    }

    func test_enhancedRestore_guardedByImagePresence() {
        let h = TimelineTestHarness(EditorState(sourceImage: img(100, 50), sourceURL: nil))
        h.state.recordUndoCheckpoint(action: "X")
        // Forge the recorded snapshot to claim enhanced was on; with no bitmap
        // the restore must keep it off.
        guard case .edit(let cap, var snap)? = h.store.popUndo()?.kind else { return XCTFail() }
        snap.showingEnhanced = true
        h.store.record(.edit(capture: cap, snapshot: snap))
        _ = h.undo()
        XCTAssertFalse(h.state.showingEnhanced)
    }
}

/// File events (delete / restore / import / capture) on the app-global timeline.
@MainActor
final class ImportUndoHistoryTests: XCTestCase {

    private func item(_ name: String) -> DeletionUndoHistory.Item {
        let url = URL(fileURLWithPath: "/tmp/\(name).seal")
        return .init(trashedURL: url, originalURL: url)
    }

    func test_recordImportation_pushesFileEvent() {
        let store = GlobalUndoStore(backend: nil)
        store.record(.fileEvent(.init(items: [item("a"), item("b")], kind: .importation,
                                      containedOpenFile: false, at: Date())))
        guard case .fileEvent(let event)? = store.popUndo()?.kind else { return XCTFail() }
        XCTAssertEqual(event.kind, .importation)
        XCTAssertEqual(event.items.count, 2)
        XCTAssertEqual(event.containedOpenFile, false)
    }

    func test_fileEvent_persistsAndDecodes() throws {
        let event = DeletionUndoHistory.Event(
            items: [item("a")], kind: .importation, containedOpenFile: false, at: Date())
        let persisted = GlobalUndoStore.Persisted(
            undoStack: [GlobalUndoEntry(at: Date(), kind: .fileEvent(event))], redoStack: [])
        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(GlobalUndoStore.Persisted.self, from: data)
        guard case .fileEvent(let e)? = decoded.undoStack.first?.kind else { return XCTFail() }
        XCTAssertEqual(e.kind, .importation)
    }

    func test_importInterleavesWithCanvasEdits_byPushOrder() {
        let store = GlobalUndoStore(backend: nil)
        let snap = EditorSnapshot(annotations: [], croppedRect: nil, focusRect: nil,
                                  sourceURL: nil, at: Date(), action: "Add Arrow")
        store.record(.edit(capture: nil, snapshot: snap))
        store.record(.fileEvent(.init(items: [item("a")], kind: .importation,
                                      containedOpenFile: false, at: Date())))
        // Chronological pop order: the newer import event undoes first.
        guard case .fileEvent? = store.popUndo()?.kind else { return XCTFail("import pops first") }
        guard case .edit? = store.popUndo()?.kind else { return XCTFail("edit pops second") }
    }

    func test_recordCapture_pushesCaptureEvent() {
        let store = GlobalUndoStore(backend: nil)
        store.record(.fileEvent(.init(items: [item("shot")], kind: .capture,
                                      containedOpenFile: false, at: Date())))
        guard case .fileEvent(let e)? = store.popUndo()?.kind else { return XCTFail() }
        XCTAssertEqual(e.kind, .capture)
    }
}

@MainActor
extension UndoUnificationTests {
    func test_zoomCheckpoint_coalescesBursts() {
        let h = TimelineTestHarness(EditorState(sourceImage: img(10, 10), sourceURL: nil))
        h.state.checkpointZoomIfNeeded()
        h.state.zoom = 0.5
        h.state.checkpointZoomIfNeeded()   // within the burst window → coalesced
        h.state.zoom = 0.7
        XCTAssertEqual(h.store.undoStack.count, 1, "a burst records ONE zoom step")
        _ = h.undo()
        XCTAssertEqual(h.state.zoom, 1.0, accuracy: 0.001,
                       "undo restores the pre-burst zoom")
    }
}

@MainActor
extension UndoUnificationTests {
    /// The reported no-op: first-time Enhance enable must undo back to OFF —
    /// the gesture checkpoints BEFORE the flag flips (the async apply used to
    /// checkpoint after, capturing an already-on state).
    func test_firstEnhanceEnable_gestureCheckpoint_undoesToOff() {
        let h = TimelineTestHarness(EditorState(sourceImage: img(10, 10), sourceURL: nil))
        // Gesture: checkpoint pre-mutation, then the flip + (async) apply land.
        h.state.recordUndoCheckpoint(action: "Enhance")
        h.state.showingEnhanced = true
        h.state.enhancedImage = h.state.sourceImage   // apply finished
        XCTAssertEqual(h.undo(), "Enhance")
        XCTAssertFalse(h.state.showingEnhanced, "undo turns the toggle OFF")
        _ = h.redo()
        XCTAssertTrue(h.state.showingEnhanced, "redo turns it back ON")
    }

    func test_discardLastCheckpoint_labelGuarded() {
        let h = TimelineTestHarness(EditorState(sourceImage: img(10, 10), sourceURL: nil))
        h.state.recordUndoCheckpoint(action: "Enhance")
        h.state.discardLastUndoCheckpoint(ifAction: "Add Arrow")
        XCTAssertTrue(h.canUndo, "mismatched label must not drop the step")
        h.state.discardLastUndoCheckpoint(ifAction: "Enhance")
        XCTAssertFalse(h.canUndo, "failed enhance drops its optimistic step")
    }

    // MARK: metadata steps (rename / summary / tags)

    func test_metadataStep_roundTripsThroughUndoRedo() {
        let h = TimelineTestHarness(EditorState(sourceImage: img(10, 10), sourceURL: nil))
        // "Manifest" the provider reads — mutated the way the controller's
        // restore write would mutate the real one.
        var manifest = MetadataUndoPatch(userTitle: "New", userSummary: "edited", tags: ["b"])
        h.state.metadataPatchProvider = { manifest }

        // A tags edit checkpoints the PRE-edit trio.
        let pre = MetadataUndoPatch(userTitle: "New", userSummary: "edited", tags: ["a"])
        h.state.recordUndoCheckpoint(action: "Edit Tags", metadata: pre)

        _ = h.undo()
        XCTAssertEqual(h.state.consumePendingRestoredMetadata(), pre,
                       "undo hands the pre-edit trio to the controller")
        XCTAssertNil(h.state.consumePendingRestoredMetadata(), "consume is one-shot")
        manifest = pre   // the controller's write took effect

        _ = h.redo()
        XCTAssertEqual(h.state.consumePendingRestoredMetadata()?.tags, ["b"],
                       "redo counterpart carried the trio as it was before undo")
    }

    func test_nonMetadataStep_leavesManifestAlone() {
        let h = TimelineTestHarness(EditorState(sourceImage: img(10, 10), sourceURL: nil))
        h.state.metadataPatchProvider = {
            XCTFail("provider must not be consulted for canvas-only steps")
            return nil
        }
        h.state.recordUndoCheckpoint(action: "Add Arrow")
        _ = h.undo()
        XCTAssertNil(h.state.consumePendingRestoredMetadata())
        _ = h.redo()
        XCTAssertNil(h.state.consumePendingRestoredMetadata())
    }

    func test_legacySnapshot_decodesNilMetadata() throws {
        let json = #"{"annotations":[],"croppedRect":null,"focusRect":null,"sourceURL":null}"#
        let snap = try JSONDecoder().decode(EditorSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.metadata)
    }

    func test_metadataPatch_fromNilMetadata_isEmptyTrio() {
        let patch = MetadataUndoPatch(from: nil)
        XCTAssertNil(patch.userTitle)
        XCTAssertNil(patch.userSummary)
        XCTAssertEqual(patch.tags, [])
    }

    // MARK: extracted snapshot mint/apply + checkpoint delegation

    func test_recordUndoCheckpoint_invokesOnCheckpointClosure() {
        let state = EditorState(sourceImage: img(200, 100), sourceURL: nil)
        var received: EditorSnapshot?
        state.onCheckpoint = { received = $0 }
        state.recordUndoCheckpoint(action: "Add Arrow")
        XCTAssertEqual(received?.action, "Add Arrow")
        XCTAssertNotNil(received?.at)
    }

    func test_applySnapshot_restoresFields_and_counterpartMirrorsCurrent() {
        let state = EditorState(sourceImage: img(200, 100), sourceURL: nil)
        let before = state.makeSnapshot(action: "Move")
        state.annotations.append(Annotation(geometry: .line(start: .zero, end: CGPoint(x: 10, y: 10)),
                                            style: Style(strokeColor: SerializableColor(.red), strokeWidth: 2)))
        let counterpart = state.counterpartSnapshot(for: before)
        XCTAssertEqual(counterpart.annotations.count, 1, "counterpart mirrors CURRENT state")
        XCTAssertEqual(counterpart.action, "Move", "label rides the counterpart")
        state.applySnapshot(before)
        XCTAssertTrue(state.annotations.isEmpty, "applySnapshot restores the snapshot's fields")
        XCTAssertTrue(state.isDirty)
    }
}

/// Task 4: image/video selection is an undoable `.navigation` step.
/// `EditorWindowController.currentDisplayedItemURL` + the recording guards in
/// `EditorController.presentFile` / `playVideoInCanvas` are UI-integration code
/// exercised by the app itself; these tests drive the controller-side pieces
/// that ARE headless-testable: `performNavigationStep`'s dispatch (via
/// `handleUndo`/`handleRedo`) and the async suppression window a file-event
/// undo/redo's `deleteBatch` opens (correction 3 in the Task 4 brief).
@MainActor
final class NavigationUndoTests: XCTestCase {

    // `config.saveFolder` persists to UserDefaults.standard (the app domain,
    // since these tests are hosted by the app) — snapshot/restore so a test's
    // temp folder never leaks into the real save location (mirrors
    // EditorBackgroundAutosaveTests).
    private static let saveFolderKey = "captureConfig.saveFolder"
    private var savedSaveFolder: Any?

    override func setUpWithError() throws {
        savedSaveFolder = UserDefaults.standard.object(forKey: Self.saveFolderKey)
    }
    override func tearDownWithError() throws {
        if let savedSaveFolder {
            UserDefaults.standard.set(savedSaveFolder, forKey: Self.saveFolderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.saveFolderKey)
        }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nav-undo-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeDummy(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x00]).write(to: url)
    }

    private func img(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    // N1: a cross-item `.edit` undo whose open FAILS (file still present on disk
    // — corrupt/newer-version/locked package — so `presentFile` early-returns via
    // `presentOpenFailure` leaving the OLD document up, and `pruneDeadTop`'s
    // fileExists check kept the entry) must NOT apply the snapshot against the
    // wrong document. It must push the popped entry back (loss-free, `at`
    // preserved) and bail without minting a counterpart. Here the injected
    // `onRecentClick` is a no-op — it never swaps the state — modelling exactly
    // the failed open (state.sourceURL stays at A, not the entry's B).
    func test_crossItemEditUndo_openFailure_pushesEntryBack_appliesNothing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let itemA = dir.appendingPathComponent("A.seal")
        let itemB = dir.appendingPathComponent("B.seal")
        try writeDummy(at: itemA)
        try writeDummy(at: itemB)   // B exists → prune keeps the entry; open still fails

        let config = CaptureConfig()
        let saver = EditorSaveCoordinator(config: config)
        let stateA = EditorState(sourceImage: img(80, 60), sourceURL: itemA)
        var openedURLs: [URL] = []
        let controller = EditorWindowController(
            state: stateA, saver: saver, config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "n1-test",
            onRecentClick: { url in openedURLs.append(url) })   // no-op: never swaps state

        // A cross-item edit checkpoint that belongs to B, not the on-screen A.
        let snapshot = EditorSnapshot(annotations: [], croppedRect: nil, focusRect: nil,
                                      sourceURL: itemB, at: Date(), action: "Add Arrow")
        let entry = GlobalUndoEntry(at: Date(timeIntervalSince1970: 42),
                                    kind: .edit(capture: itemB, snapshot: snapshot))
        controller.globalUndo.pushUndo(entry)

        controller.handleUndo()

        XCTAssertEqual(openedURLs, [itemB], "the cross-item open was attempted")
        XCTAssertEqual(controller.globalUndo.undoStack, [entry],
                       "failed open pushes the ORIGINAL entry back (at preserved), loss-free")
        XCTAssertTrue(controller.globalUndo.redoStack.isEmpty,
                      "no counterpart is minted when the open failed")
        XCTAssertEqual(controller.state?.sourceURL, itemA,
                       "the old document is untouched — no snapshot applied, no rename")
        XCTAssertTrue(FileManager.default.fileExists(atPath: itemA.path),
                      "A's file was never renamed out from under it")
    }

    /// `performNavigationStep` (reached via `handleUndo`) opens the entry's
    /// `from` URL through the SAME `onRecentClickStored` callback a strip
    /// click uses, and does so while `navigationRecordingSuppressed` is true —
    /// the exact guard `presentFile`/`playVideoInCanvas` consult before
    /// minting a fresh `.navigation` entry. Also confirms the popped entry's
    /// counterpart lands on the redo stack unchanged (⌘⇧Z round-trips it).
    func test_performNavigationStep_opensFromURL_whileRecordingIsSuppressed() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let from = dir.appendingPathComponent("nav-a.seal")
        let to = dir.appendingPathComponent("nav-b.seal")
        try writeDummy(at: from)
        try writeDummy(at: to)

        var openedURLs: [URL] = []
        var suppressedDuringOpen = false
        var controllerRef: EditorWindowController?
        let config = CaptureConfig()
        let saver = EditorSaveCoordinator(config: config)
        let controller = EditorWindowController(
            state: nil, saver: saver, config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "nav-test",
            onRecentClick: { url in
                openedURLs.append(url)
                suppressedDuringOpen = controllerRef?.navigationRecordingSuppressed ?? false
            })
        controllerRef = controller

        controller.globalUndo.record(.navigation(from: from, to: to))
        controller.handleUndo()

        XCTAssertEqual(openedURLs, [from], "undo opens the entry's `from` endpoint")
        XCTAssertTrue(suppressedDuringOpen,
                      "navigationRecordingSuppressed must be true while the undo-driven reopen runs")
        XCTAssertFalse(controller.isPerformingUndoRedo,
                       "reset after performTimelineStep's synchronous dispatch completes")
        XCTAssertEqual(controller.globalUndo.undoStack.count, 0)
        guard case .navigation(let f, let t)? = controller.globalUndo.redoStack.last?.kind else {
            return XCTFail("counterpart must land on the redo stack")
        }
        XCTAssertEqual(f, from); XCTAssertEqual(t, to)
    }

    /// Correction 3's hazard: `deleteBatch` (the async half of a file-event
    /// undo/redo) can still be mid-flight — including its open-file neighbor
    /// switch — AFTER `performTimelineStep`'s synchronous `defer` has already
    /// reset `isPerformingUndoRedo`. `suppressNavigationRecording` must bridge
    /// exactly that gap: true immediately after the synchronous dispatch
    /// returns, false once the async work is done.
    func test_fileEventUndo_asyncTail_keepsNavigationSuppressedUntilComplete() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = CaptureConfig()
        config.saveFolder = dir
        let source = dir.appendingPathComponent("capture.seal")
        try writeDummy(at: source)

        let saver = EditorSaveCoordinator(config: config)
        let controller = EditorWindowController(
            state: nil, saver: saver, config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "nav-test-async",
            onRecentClick: { _ in })

        // A `.capture` file event: undo (redo:false) re-deletes it — routes
        // through `performFileEvent`'s ASYNC `deleteBatch` branch.
        controller.globalUndo.record(.fileEvent(.init(
            items: [.init(trashedURL: dir.appendingPathComponent("Deleted/capture.seal"),
                          originalURL: source)],
            kind: .capture, containedOpenFile: false, at: Date())))

        controller.handleUndo()

        // The synchronous dispatch has returned — performTimelineStep's OWN
        // flag is already reset...
        XCTAssertFalse(controller.isPerformingUndoRedo)
        // ...but deleteBatch's Task hasn't run yet, so the async-tail flag
        // must still be bridging the gap.
        XCTAssertTrue(controller.debugSuppressNavigationRecording,
                      "must stay suppressed until deleteBatch's Task completes")

        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(controller.debugSuppressNavigationRecording,
                       "flag must reset once the async reopen work completes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "the file event's undo re-deleted the capture")
    }

    /// Regression: undoing a capture moves it to Deleted AND switches the strip
    /// to the Deleted tab. Redo must still restore it — the timeline is global,
    /// so it must not be gated on the current tab (the bug: redo silently
    /// no-op'd on the Deleted tab, leaving the capture stranded in Deleted).
    func test_captureUndo_thenRedo_restoresEvenAfterSwitchingToDeletedTab() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = CaptureConfig()
        config.saveFolder = dir
        let source = dir.appendingPathComponent("capture.seal")
        try writeDummy(at: source)

        let saver = EditorSaveCoordinator(config: config)
        let controller = EditorWindowController(
            state: nil, saver: saver, config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "capture-undo-redo",
            onRecentClick: { _ in })

        // A capture that just landed: trashedURL is a placeholder (== originalURL)
        // until an undo moves it (matches the real capture recording).
        controller.globalUndo.record(.fileEvent(.init(
            items: [.init(trashedURL: source, originalURL: source)],
            kind: .capture, containedOpenFile: false, at: Date())))

        // Undo → async deleteBatch re-deletes into Deleted/ and switches the
        // strip to the Deleted tab.
        controller.handleUndo()
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "undo moved the capture to Deleted")
        XCTAssertEqual(controller.debugCurrentTab, .deleted,
                       "the undo switched the strip to the Deleted tab (the trap condition)")
        XCTAssertTrue(controller.globalUndo.canRedo, "a redo counterpart is available")

        // Redo must restore it despite the undo having left us on the Deleted tab.
        controller.handleRedo()
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "redo restored the capture from Deleted")
    }

    /// The overlap hazard: `performTimelineStep` returns immediately after
    /// scheduling `deleteBatch`'s Task, so two rapid ⌘Z presses over two
    /// separate file events can have TWO of those Tasks in flight at once,
    /// sharing the one suppression flag/counter. With the old plain Bool,
    /// whichever Task finished first cleared the flag while the OTHER Task's
    /// neighbor switch was still pending, letting that switch mint a spurious
    /// `.navigation` entry mid-undo. Drive the real seam (two back-to-back
    /// `handleUndo()` calls, no `await` between them) and assert the
    /// invariant that must hold at every sampled tick of the async tail: if
    /// suppression has already cleared, BOTH re-deletes must already be done.
    /// Under the buggy Bool this is caught in practice — the first Task to
    /// finish clears the shared flag while the second file often still
    /// exists.
    func test_fileEventUndo_overlappingAsyncTails_staySuppressedUntilBothComplete() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = CaptureConfig()
        config.saveFolder = dir
        let sourceA = dir.appendingPathComponent("capture-a.seal")
        let sourceB = dir.appendingPathComponent("capture-b.seal")
        try writeDummy(at: sourceA)
        try writeDummy(at: sourceB)

        let saver = EditorSaveCoordinator(config: config)
        let controller = EditorWindowController(
            state: nil, saver: saver, config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "nav-test-overlap",
            onRecentClick: { _ in })

        // Two independent `.capture` file events, each undoable via the async
        // `deleteBatch` branch of `performFileEvent`.
        controller.globalUndo.record(.fileEvent(.init(
            items: [.init(trashedURL: dir.appendingPathComponent("Deleted/capture-a.seal"),
                          originalURL: sourceA)],
            kind: .capture, containedOpenFile: false, at: Date())))
        controller.globalUndo.record(.fileEvent(.init(
            items: [.init(trashedURL: dir.appendingPathComponent("Deleted/capture-b.seal"),
                          originalURL: sourceB)],
            kind: .capture, containedOpenFile: false, at: Date())))

        // Rapid ⌘Z ⌘Z: pop both events and schedule both deleteBatch Tasks
        // before either one's async tail has drained.
        controller.handleUndo()
        controller.handleUndo()

        XCTAssertEqual(controller.debugNavigationSuppressionCount, 2,
                       "two overlapping deleteBatch Tasks must both hold the suppression")
        XCTAssertTrue(controller.debugSuppressNavigationRecording)

        // Poll the async tail. The moment suppression reads false, both
        // re-deletes must already have completed — that's the overlap
        // guarantee the counter exists to provide.
        var observedClear = false
        for _ in 0..<200 {
            await Task.yield()
            if !controller.debugSuppressNavigationRecording {
                observedClear = true
                break
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(observedClear, "suppression must eventually clear once both Tasks drain")
        XCTAssertEqual(controller.debugNavigationSuppressionCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceA.path),
                       "capture A's overlapping re-delete must have completed before suppression cleared")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceB.path),
                       "capture B's overlapping re-delete must have completed before suppression cleared")
    }
}
