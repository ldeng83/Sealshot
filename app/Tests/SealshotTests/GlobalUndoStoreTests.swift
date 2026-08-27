import XCTest
@testable import Sealshot

@MainActor
final class GlobalUndoStoreTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/gut/\(name).seal") }
    private func snap(action: String) -> EditorSnapshot {
        EditorSnapshot(annotations: [], croppedRect: nil, focusRect: nil,
                       sourceURL: nil, at: Date(), action: action)
    }
    private func editKind(_ name: String?, action: String = "Add Arrow") -> GlobalUndoEntry.Kind {
        .edit(capture: name.map(url), snapshot: snap(action: action))
    }

    func test_record_clearsRedo_andCaps() {
        let store = GlobalUndoStore(backend: nil)
        store.record(editKind("a"))
        _ = store.popUndo().map(store.pushRedo)
        XCTAssertTrue(store.canRedo)
        store.record(editKind("b"))
        XCTAssertFalse(store.canRedo, "any new action clears the global redo stack")
        for i in 0..<(GlobalUndoStore.maxDepth + 10) { store.record(editKind("x\(i)")) }
        XCTAssertEqual(store.undoStack.count, GlobalUndoStore.maxDepth)
    }

    func test_navigationCoalescing_mergesConsecutive_dropsRoundTrip() {
        let store = GlobalUndoStore(backend: nil)
        store.record(.navigation(from: url("a"), to: url("b")))
        store.record(.navigation(from: url("b"), to: url("c")))
        XCTAssertEqual(store.undoStack.count, 1)
        guard case .navigation(let f, let t) = store.topUndo?.kind else { return XCTFail() }
        XCTAssertEqual(f, url("a")); XCTAssertEqual(t, url("c"))
        store.record(.navigation(from: url("c"), to: url("a")))
        XCTAssertTrue(store.undoStack.isEmpty, "browse-and-return coalesces to nothing")
        // A non-navigation entry in between blocks coalescing.
        store.record(.navigation(from: url("a"), to: url("b")))
        store.record(editKind("b"))
        store.record(.navigation(from: url("b"), to: url("c")))
        XCTAssertEqual(store.undoStack.count, 3)
    }

    // N2: a fresh append of `.navigation(X→X)` (re-clicking the playing video's
    // tile, re-opening the already-open item) is a no-op that must NOT append a
    // phantom entry and must NOT clear the redo stack.
    func test_record_degenerateSameEndpointNavigation_dropsWithoutTouchingStacks() {
        let store = GlobalUndoStore(backend: nil)
        store.record(editKind("a"))                                    // non-nav top
        _ = store.popUndo().map(store.pushRedo)                        // seed a redo entry
        store.record(editKind("keep"))                                 // rebuild an undo top
        // Re-seed redo without clearing the new undo top.
        store.pushRedo(GlobalUndoEntry(at: Date(), kind: editKind("r")))
        let undoBefore = store.undoStack
        let redoBefore = store.redoStack
        store.record(.navigation(from: url("x"), to: url("x")))
        XCTAssertEqual(store.undoStack, undoBefore, "same-endpoint nav appends nothing")
        XCTAssertEqual(store.redoStack, redoBefore, "same-endpoint nav must not clear redo")
    }

    // N3: a `from == nil` navigation (launch auto-open of the newest capture)
    // must never be recorded — it would wipe the redo stack just loaded from
    // disk, so redo never survives relaunch.
    func test_record_fromNilNavigation_dropsAndPreservesRedo() {
        let store = GlobalUndoStore(backend: nil)
        store.record(editKind("a"))
        store.pushRedo(GlobalUndoEntry(at: Date(), kind: editKind("r")))  // non-empty redo, as if loaded
        let undoBefore = store.undoStack
        let redoBefore = store.redoStack
        store.record(.navigation(from: nil, to: url("newest")))
        XCTAssertEqual(store.undoStack, undoBefore, "from-nil nav appends nothing")
        XCTAssertEqual(store.redoStack, redoBefore, "from-nil nav must not clear the loaded redo stack")
    }

    func test_removeTopEdit_matchesActionAndCapture() {
        let store = GlobalUndoStore(backend: nil)
        store.record(editKind("a", action: "Add Line"))
        store.removeTopEdit(action: "Move", capture: url("a"))      // wrong action
        XCTAssertEqual(store.undoStack.count, 1)
        store.removeTopEdit(action: "Add Line", capture: url("b"))  // wrong capture
        XCTAssertEqual(store.undoStack.count, 1)
        store.removeTopEdit(action: "Add Line", capture: url("a"))
        XCTAssertTrue(store.undoStack.isEmpty)
    }

    func test_pruneDeadTop_perKind() {
        let store = GlobalUndoStore(backend: nil)
        store.record(editKind("dead"))
        store.pruneDeadTop(redo: false, fileExists: { _ in false },
                           revertAvailable: { _ in true }, scratchAlive: false)
        XCTAssertTrue(store.undoStack.isEmpty)
        store.record(.revert(capture: url("alive")))
        store.pruneDeadTop(redo: false, fileExists: { _ in true },
                           revertAvailable: { _ in false }, scratchAlive: false)
        XCTAssertTrue(store.undoStack.isEmpty, "revert with no session payload prunes")
        // Seed via pushUndo: record() now drops from-nil navs at the door, but
        // timelines persisted by older builds can still contain them, and
        // prune-at-pop is their only cleanup path — keep that branch exercised.
        store.pushUndo(GlobalUndoEntry(at: Date(), kind: .navigation(from: nil, to: url("b"))))
        store.pruneDeadTop(redo: false, fileExists: { _ in true },
                           revertAvailable: { _ in true }, scratchAlive: false)
        XCTAssertTrue(store.undoStack.isEmpty, "undoing nav to a dead scratch prunes")
    }

    func test_rebindScratch_renameCapture_removeCapture() {
        let store = GlobalUndoStore(backend: nil)
        store.record(editKind(nil))
        store.rebindScratch(to: url("saved"))
        guard case .edit(let c, _) = store.topUndo?.kind else { return XCTFail() }
        XCTAssertEqual(c, url("saved"))
        store.renameCapture(from: url("saved"), to: url("renamed"))
        guard case .edit(let c2, _) = store.topUndo?.kind else { return XCTFail() }
        XCTAssertEqual(c2, url("renamed"))
        store.removeCapture(url("renamed"))
        XCTAssertTrue(store.undoStack.isEmpty)
    }

    /// Contract: the controller consults `isPerformingUndoRedo` (or the async
    /// `navigationSuppressionCount` tail — see EditorWindowController) before
    /// recording. Store-level proxy: an undo-driven switch must not add a
    /// fresh entry — only the counterpart push happens.
    func test_navigationRecording_isSuppressedDuringUndoRedo() {
        let store = GlobalUndoStore(backend: nil)
        store.record(.navigation(from: URL(fileURLWithPath: "/tmp/a.seal"),
                                 to: URL(fileURLWithPath: "/tmp/b.seal")))
        let popped = store.popUndo()
        XCTAssertNotNil(popped)
        // undo applies the switch WITHOUT recording; only the counterpart push happens:
        store.pushRedo(popped!)
        XCTAssertEqual(store.undoStack.count, 0)
        XCTAssertEqual(store.redoStack.count, 1)
    }

    func test_pushCounterpart_pushesToOppositeStack() {
        let store = GlobalUndoStore(backend: nil)
        // After an undo, the counterpart goes on the redo stack.
        store.pushCounterpart(.revert(capture: url("a")), redo: false)
        XCTAssertTrue(store.canRedo)
        XCTAssertFalse(store.canUndo)
        // After a redo, the counterpart goes on the undo stack.
        store.pushCounterpart(.revert(capture: url("a")), redo: true)
        XCTAssertTrue(store.canUndo)
    }

    func test_pruneDeadTop_fileEvent_isKindAware() {
        let store = GlobalUndoStore(backend: nil)
        let trashed = URL(fileURLWithPath: "/save/Deleted/x.seal")
        let original = URL(fileURLWithPath: "/save/x.seal")
        // Undoing a deletion restores from the trash — live iff the trashed copy exists.
        store.record(.fileEvent(.init(items: [.init(trashedURL: trashed, originalURL: original)],
                                      kind: .deletion, containedOpenFile: false, at: Date())))
        store.pruneDeadTop(redo: false, fileExists: { $0 == trashed },
                           revertAvailable: { _ in false }, scratchAlive: false)
        XCTAssertEqual(store.undoStack.count, 1, "deletion undo needs the trashed copy — live")
        store.pruneDeadTop(redo: false, fileExists: { _ in false },
                           revertAvailable: { _ in false }, scratchAlive: false)
        XCTAssertTrue(store.undoStack.isEmpty, "trashed copy gone → deletion undo is dead")
    }

    /// Step 1 (Task 5): the store-level round trip for `.videoMetadata` — no
    /// controller involved. The store's generic push/pop machinery already
    /// handles this kind (Task 3 groundwork), so this is expected to pass
    /// immediately; it's kept as a regression guard for the kind's shape.
    func test_videoMetadata_roundTrip() {
        let store = GlobalUndoStore(backend: nil)
        let item = url("clip")
        let before = MetadataUndoPatch(userTitle: "old", userSummary: nil, tags: [])
        let after = MetadataUndoPatch(userTitle: "new", userSummary: nil, tags: ["demo"])
        store.record(.videoMetadata(item: item, before: before, after: after))
        guard case .videoMetadata(let i, let b, let a) = store.popUndo()?.kind else { return XCTFail() }
        XCTAssertEqual(i, item); XCTAssertEqual(b.userTitle, "old"); XCTAssertEqual(a.tags, ["demo"])
    }

    /// Additional store-level coverage beyond the brief's Step 1: exercises
    /// the two behaviors `performVideoMetadataStep` actually leans on —
    /// `renameCapture` repointing a live `.videoMetadata` item, and
    /// `pruneDeadTop` treating it as dead once the file is gone.
    func test_videoMetadata_renameRepoints_andPrunesWhenFileGone() {
        let store = GlobalUndoStore(backend: nil)
        let before = MetadataUndoPatch(userTitle: "old", userSummary: nil, tags: [])
        let after = MetadataUndoPatch(userTitle: "new", userSummary: nil, tags: ["demo"])
        store.record(.videoMetadata(item: url("clip"), before: before, after: after))
        store.renameCapture(from: url("clip"), to: url("clip-renamed"))
        guard case .videoMetadata(let item, _, _) = store.topUndo?.kind else { return XCTFail() }
        XCTAssertEqual(item, url("clip-renamed"))
        store.pruneDeadTop(redo: false, fileExists: { _ in false },
                           revertAvailable: { _ in true }, scratchAlive: false)
        XCTAssertTrue(store.undoStack.isEmpty, "videoMetadata entry is dead once its file is gone")
    }

    func test_persistence_roundTrip_filtersSessionOnlyEntries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backend = GlobalUndoTimelineStore(
            fileURL: dir.appendingPathComponent("undo-timeline.json"), keyProvider: nil)
        let store = GlobalUndoStore(backend: backend)
        store.record(editKind("a"))
        store.record(.revert(capture: url("a")))       // session-only
        store.record(editKind(nil))                    // unsaved scratch: session-only
        store.record(.navigation(from: url("a"), to: url("b")))
        let reloaded = GlobalUndoStore(backend: backend)
        XCTAssertEqual(reloaded.undoStack.count, 2, "revert + scratch edits filtered on save")
        guard case .navigation = reloaded.topUndo?.kind else { return XCTFail() }
    }
}

/// Drives an `EditorState` through the app-global timeline exactly as
/// `EditorWindowController` does: checkpoints record `.edit` entries via
/// `onCheckpoint`, and undo/redo pop + push-the-counterpart + apply (the
/// in-place path of `performEditStep`). Lets the migrated per-image undo tests
/// assert against the real store instead of the retired per-state stacks.
@MainActor
final class TimelineTestHarness {
    let store = GlobalUndoStore(backend: nil)
    let state: EditorState

    init(_ state: EditorState) {
        self.state = state
        state.onCheckpoint = { [store, weak state] snapshot in
            store.record(.edit(capture: state?.sourceURL, snapshot: snapshot))
        }
        state.onDiscardCheckpoint = { [store, weak state] action in
            store.removeTopEdit(action: action, capture: state?.sourceURL)
        }
    }

    var canUndo: Bool { store.canUndo }
    var canRedo: Bool { store.canRedo }

    @discardableResult func undo() -> String? { step(redo: false) }
    @discardableResult func redo() -> String? { step(redo: true) }

    private func step(redo: Bool) -> String? {
        guard let entry = redo ? store.popRedo() : store.popUndo(),
              case .edit(_, let snapshot) = entry.kind else { return nil }
        let counterpart = GlobalUndoEntry(at: Date(),
            kind: .edit(capture: state.sourceURL, snapshot: state.counterpartSnapshot(for: snapshot)))
        if redo { store.pushUndo(counterpart) } else { store.pushRedo(counterpart) }
        state.applySnapshot(snapshot)
        return snapshot.action
    }
}
