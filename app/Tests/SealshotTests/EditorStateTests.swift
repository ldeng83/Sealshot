import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class EditorStateTests: XCTestCase {

    private func makeImage(width: Int = 100, height: Int = 100) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    func testInitialState_defaults() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        XCTAssertEqual(state.selectedTool, .select)
        XCTAssertEqual(state.annotations, [])
        XCTAssertNil(state.croppedRect)
        XCTAssertNil(state.pendingCrop)
        XCTAssertNil(state.selectedAnnotationID)
    }

    func testCommitCrop_validRect_setsCroppedRectAndClearsPending() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.pendingCrop = CGRect(x: 10, y: 10, width: 50, height: 50)
        state.commitCrop()
        XCTAssertEqual(state.croppedRect, CGRect(x: 10, y: 10, width: 50, height: 50))
        XCTAssertNil(state.pendingCrop)
    }

    func testCommitCrop_zeroAreaRect_doesNothing() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.pendingCrop = CGRect(x: 10, y: 10, width: 0, height: 0)
        state.commitCrop()
        XCTAssertNil(state.croppedRect)
        XCTAssertNil(state.pendingCrop)
    }

    func testCommitCrop_translatesExistingAnnotations() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let arrow = Annotation(
            geometry: .arrow(start: CGPoint(x: 20, y: 20), end: CGPoint(x: 40, y: 40)),
            style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        )
        state.annotations = [arrow]
        state.pendingCrop = CGRect(x: 10, y: 10, width: 50, height: 50)
        state.commitCrop()
        XCTAssertEqual(state.annotations.count, 1)
        if case let .arrow(start, end) = state.annotations[0].geometry {
            XCTAssertEqual(start, CGPoint(x: 10, y: 10))
            XCTAssertEqual(end,   CGPoint(x: 30, y: 30))
        } else {
            XCTFail("expected arrow")
        }
    }

    func testAbandonCrop_clearsPendingWithoutAffectingCommitted() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.croppedRect = CGRect(x: 5, y: 5, width: 30, height: 30)
        state.pendingCrop = CGRect(x: 10, y: 10, width: 50, height: 50)
        state.abandonCrop()
        XCTAssertNil(state.pendingCrop)
        XCTAssertEqual(state.croppedRect, CGRect(x: 5, y: 5, width: 30, height: 30))
    }

    func testToolChange_clearsPendingCrop() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.selectedTool = .crop
        state.pendingCrop = CGRect(x: 10, y: 10, width: 50, height: 50)
        state.selectedTool = .arrow
        XCTAssertNil(state.pendingCrop)
    }

    func testToolChange_toDrawingTool_clearsSelection() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        // Default tool is the neutral .select.
        state.selectedAnnotationID = UUID()
        state.selectedTool = .arrow
        XCTAssertNil(state.selectedAnnotationID)
    }

    func testSelection_persistsWhileInSelectTool() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let id = UUID()
        state.selectedAnnotationID = id
        // Switching to a drawing/crop tool clears the selection.
        state.selectedTool = .crop
        XCTAssertNil(state.selectedAnnotationID, "drawing/crop tool clears selection")
        state.selectedAnnotationID = id
        state.selectedTool = .select
        XCTAssertEqual(state.selectedAnnotationID, id, "selection survives in the neutral .select tool")
    }

    func testInfoPanel_defaultsOpenAndToggles() {
        // The editor opens in Info mode by default ('i' selected).
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        XCTAssertTrue(state.showsInfoPanel)
        state.toggleInfoPanel()
        XCTAssertFalse(state.showsInfoPanel)
        state.toggleInfoPanel()
        XCTAssertTrue(state.showsInfoPanel)
    }

    func testUserSelectedTool_exitsInfo_evenWhenToolUnchanged() {
        // Clicking a tool always exits Info — including re-clicking the already
        // active Select tool while in Info (the bug where both stayed highlighted).
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        XCTAssertEqual(state.selectedTool, .select)
        XCTAssertTrue(state.showsInfoPanel)        // default Info on
        state.userSelectedTool(.select)            // same tool, but should exit Info
        XCTAssertFalse(state.showsInfoPanel)
        XCTAssertEqual(state.selectedTool, .select)
    }

    func testFindInImageIsExclusiveWithToolModes() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.selectedAnnotationIDs = [UUID()]

        state.showImageTextSearchPanel()
        XCTAssertTrue(state.showsImageTextSearchPanel)
        XCTAssertFalse(state.showsInfoPanel)
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty)
        XCTAssertEqual(state.imageTextSearchStatus, .recognizing)
        XCTAssertEqual(state.imageTextSearchScanStage, .waitingForEnhancementDecision)

        // Re-clicking even the already-underlying Select tool exits Find.
        state.userSelectedTool(.select)
        XCTAssertFalse(state.showsImageTextSearchPanel)
        XCTAssertEqual(state.sidebarPanelMode, .properties)
        XCTAssertEqual(state.imageTextSearchStatus, .idle)
        XCTAssertEqual(state.imageTextSearchScanStage, .ready)
    }

    func testFindInImageFallsBackToWholeImageWithoutFocusArea() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.imageTextSearchScope = .focusArea
        XCTAssertNil(state.focusRect)

        state.showImageTextSearchPanel()

        XCTAssertEqual(state.imageTextSearchScope, .wholeImage)
    }

    func testEscapeToInfo_selectsInfoNotSelectTool() {
        // Esc's resting state surfaces file Info ('i' selected) rather than the
        // neutral Select tool. The tool drops to .select underneath (so the
        // toolbar tool highlight clears and 'i' is the lit control).
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.userSelectedTool(.arrow)          // a drawing tool, Info off
        XCTAssertFalse(state.showsInfoPanel)
        state.escapeToInfo()
        XCTAssertTrue(state.showsInfoPanel, "Esc should select the Info ('i') pill")
        XCTAssertEqual(state.selectedTool, .select, "tool resets to neutral Select underneath")
    }

    func testInfoPanel_enteringInfoKeepsSelectedTool() {
        // Info must NOT change the remembered tool — its pill is just visually
        // de-highlighted while 'i' is active. Clicking an object still works
        // under any tool (canvas selects an object hit before the per-tool
        // behavior), so the highlight returns to the original tool afterward.
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.selectedTool = .pen
        state.toggleInfoPanel()
        XCTAssertTrue(state.showsInfoPanel)
        XCTAssertEqual(state.selectedTool, .pen)
    }

    func testInfoPanel_selectingAnyToolExitsInfo() {
        // 'i' is a peer of the tools: picking any tool (even Hand) exits Info.
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        XCTAssertTrue(state.showsInfoPanel)   // default Info on
        state.selectedTool = .hand
        XCTAssertFalse(state.showsInfoPanel)
    }

    func testInfoPanel_pillStaysHighlightedWhenObjectSelected() {
        // 'i' behaves like a tool button: selecting an object shows its
        // properties in the sidebar but does NOT change the toolbar highlight —
        // the 'i' pill stays lit. (That the sidebar DISPLAY yields to the
        // selection is covered by SidebarPanelModeTests.showsInfo.)
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        XCTAssertTrue(state.showsInfoPanel)   // default Info on
        state.selectedAnnotationIDs = [UUID()]
        XCTAssertTrue(state.showsInfoPanel, "Info pill stays highlighted while an object is selected")
    }

    func testShowInfoPanel_clearsSelectionSoInfoDisplays() {
        // Bug: draw a line (auto-selected), click 'i' → Info must actually show.
        // The sidebar only DISPLAYS Info when nothing is selected, so clicking
        // 'i' clears the selection. The active tool is untouched.
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.selectedTool = .line              // exits Info → .properties, clears selection
        state.selectedAnnotationIDs = [UUID()]  // the just-drawn line is selected
        XCTAssertFalse(state.showsInfoPanel)
        state.showInfoPanel()                   // click 'i'
        XCTAssertTrue(state.showsInfoPanel, "Info mode on")
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty, "selection cleared so Info displays")
        XCTAssertEqual(state.selectedTool, .line, "active tool unchanged")
    }

    func testShowInfoPanel_noOpWhenAlreadyDisplayed() {
        // Bug: clicking the already-lit 'i' must NOT toggle Info off — Info keeps
        // displaying (the pill is a tool button, not an on/off switch).
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.showInfoPanel()
        XCTAssertTrue(state.showsInfoPanel)
        state.showInfoPanel()                   // click the lit pill again
        XCTAssertTrue(state.showsInfoPanel, "Info stays displayed on a repeat click")
    }

    func testShowInfoPanel_reShowsWhenObjectSelectedUnderInfoMode() {
        // Info mode on, then an object gets selected (sidebar shows its
        // properties, pill still lit). Clicking 'i' brings Info back on screen by
        // clearing the selection — so the lit pill is never an inert control.
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        XCTAssertTrue(state.showsInfoPanel)     // default Info on
        state.selectedAnnotationIDs = [UUID()]  // selection now overrides the Info display
        state.showInfoPanel()
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty, "selection cleared")
        XCTAssertTrue(state.showsInfoPanel)
    }

    func testToggleInfoPanel_showingClearsSelection_thenHides() {
        // The menu "Show / Hide Info Panel" still toggles, and showing it clears
        // the selection so Info actually displays.
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.selectedTool = .line
        state.selectedAnnotationIDs = [UUID()]
        XCTAssertFalse(state.showsInfoPanel)
        state.toggleInfoPanel()                 // show
        XCTAssertTrue(state.showsInfoPanel)
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty)
        state.toggleInfoPanel()                 // hide
        XCTAssertFalse(state.showsInfoPanel)
    }

    // MARK: - Undo / Redo

    func testUndo_emptyStack_isNoOp() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let h = TimelineTestHarness(state)
        XCTAssertFalse(h.canUndo)
        h.undo()
        XCTAssertEqual(state.annotations.count, 0)
    }

    func testUndo_restoresPriorAnnotations() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let h = TimelineTestHarness(state)
        state.recordUndoCheckpoint()
        state.annotations = [
            Annotation(
                geometry: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)),
                style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
            )
        ]
        XCTAssertEqual(state.annotations.count, 1)
        h.undo()
        XCTAssertEqual(state.annotations.count, 0)
        XCTAssertTrue(h.canRedo)
    }

    func testRedo_replaysUndoneAction() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let h = TimelineTestHarness(state)
        state.recordUndoCheckpoint()
        state.annotations = [
            Annotation(
                geometry: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)),
                style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
            )
        ]
        h.undo()
        XCTAssertEqual(state.annotations.count, 0)
        h.redo()
        XCTAssertEqual(state.annotations.count, 1)
    }

    func testNewActionAfterUndo_clearsRedoStack() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let h = TimelineTestHarness(state)
        state.recordUndoCheckpoint()
        state.annotations = [
            Annotation(
                geometry: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)),
                style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
            )
        ]
        h.undo()
        XCTAssertTrue(h.canRedo)
        state.recordUndoCheckpoint()
        XCTAssertFalse(h.canRedo)
    }

    func testCommitCrop_pushesUndoCheckpoint() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let h = TimelineTestHarness(state)
        state.pendingCrop = CGRect(x: 10, y: 10, width: 50, height: 50)
        XCTAssertFalse(h.canUndo)
        state.commitCrop()
        XCTAssertTrue(h.canUndo)
        h.undo()
        XCTAssertNil(state.croppedRect)
    }

    // MARK: - Selection helpers

    func testUpdateGeometry_mutatesGeometryAndRecordsUndo() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let arrow = Annotation(
            geometry: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)),
            style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        )
        state.annotations = [arrow]
        let h = TimelineTestHarness(state)
        XCTAssertFalse(h.canUndo)
        state.updateGeometry(id: arrow.id) { geometry in
            if case let .arrow(_, end) = geometry {
                geometry = .arrow(start: CGPoint(x: 5, y: 5), end: end)
            }
        }
        XCTAssertTrue(h.canUndo)
        if case let .arrow(start, _) = state.annotations[0].geometry {
            XCTAssertEqual(start, CGPoint(x: 5, y: 5))
        } else {
            XCTFail("expected arrow")
        }
    }

    func testDeleteSelected_removesAndClearsSelection() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let a = Annotation(
            geometry: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)),
            style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        )
        let b = Annotation(
            geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 20, height: 20)),
            style: Style(strokeColor: SerializableColor(.blue), strokeWidth: 3)
        )
        state.annotations = [a, b]
        state.selectedAnnotationID = a.id
        let h = TimelineTestHarness(state)
        state.deleteSelected()
        XCTAssertEqual(state.annotations.map(\.id), [b.id])
        XCTAssertNil(state.selectedAnnotationID)
        XCTAssertTrue(h.canUndo)
    }

    func testDeleteSelected_nilSelection_isNoOp() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let a = Annotation(
            geometry: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)),
            style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        )
        state.annotations = [a]
        XCTAssertNil(state.selectedAnnotationID)
        let h = TimelineTestHarness(state)
        state.deleteSelected()
        XCTAssertEqual(state.annotations.count, 1)
        XCTAssertFalse(h.canUndo)
    }

    func test_newPropertyDefaults() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)

        XCTAssertEqual(state.zoom, 1.0)
        XCTAssertEqual(state.bottomTab, .recent)
        XCTAssertEqual(state.strokeWidth, 4.0)
        XCTAssertNil(state.cropAspectRatio)
    }

    func test_strokeWidth_isPerTool() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.selectedTool = .arrow
        state.strokeWidth = 10
        // A different tool keeps its own width (default), unaffected by Arrow.
        state.selectedTool = .rectangle
        XCTAssertEqual(state.strokeWidth, 4.0)
        state.strokeWidth = 7
        // Back to Arrow — its width is remembered, not overwritten by Rectangle.
        state.selectedTool = .arrow
        XCTAssertEqual(state.strokeWidth, 10)
        state.selectedTool = .rectangle
        XCTAssertEqual(state.strokeWidth, 7)
    }

    // MARK: - updateSelectedStyle

    func test_updateSelectedStyle_mutatesSelectedAndUndoRestores() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let red = SerializableColor(r: 1, g: 0, b: 0, a: 1)
        let arrow = Annotation(geometry: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)),
                               style: Style(strokeColor: red, strokeWidth: 3))
        state.annotations = [arrow]
        state.selectedAnnotationID = arrow.id
        let h = TimelineTestHarness(state)

        state.recordUndoCheckpoint()           // caller checkpoints once at interaction start
        state.updateSelectedStyle { $0.opacity = 0.5 }
        state.updateSelectedStyle { $0.strokeWidth = 9 }

        XCTAssertEqual(state.annotations[0].style.opacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.annotations[0].style.strokeWidth, 9)

        h.undo()
        XCTAssertEqual(state.annotations[0].style.opacity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(state.annotations[0].style.strokeWidth, 3)
    }

    func test_updateSelectedStyle_noopWhenNothingSelected() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.annotations = []
        state.selectedAnnotationID = nil
        state.updateSelectedStyle { $0.opacity = 0.2 }   // must not crash
        XCTAssertTrue(state.annotations.isEmpty)
    }

    // MARK: - Multi-selection

    func testSelectOnly_replacesSelection() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let a = UUID(), b = UUID()
        state.selectedAnnotationIDs = [a]
        state.selectOnly(b)
        XCTAssertEqual(state.selectedAnnotationIDs, [b])
        XCTAssertEqual(state.primarySelectionID, b)
    }

    func testToggleSelection_addsAndRemoves() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let a = UUID(), b = UUID()
        state.toggleSelection(a)
        XCTAssertEqual(state.selectedAnnotationIDs, [a])
        XCTAssertEqual(state.primarySelectionID, a)
        state.toggleSelection(b)
        XCTAssertEqual(state.selectedAnnotationIDs, [a, b])
        XCTAssertEqual(state.primarySelectionID, b)
        state.toggleSelection(b)
        XCTAssertEqual(state.selectedAnnotationIDs, [a])
        XCTAssertEqual(state.primarySelectionID, a)   // primary falls back to remaining
    }

    func testSelectedAnnotationID_bridgesToPrimary() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let a = UUID()
        state.selectedAnnotationID = a
        XCTAssertEqual(state.selectedAnnotationIDs, [a])
        XCTAssertEqual(state.primarySelectionID, a)
        XCTAssertEqual(state.selectedAnnotationID, a)
        state.selectedAnnotationID = nil
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty)
        XCTAssertNil(state.primarySelectionID)
    }

    func testDeleteSelected_removesAllSelected_andUndoRestores() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let s = Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        let a1 = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)), style: s)
        let a2 = Annotation(geometry: .rectangle(rect: CGRect(x: 20, y: 20, width: 10, height: 10)), style: s)
        let a3 = Annotation(geometry: .rectangle(rect: CGRect(x: 40, y: 40, width: 10, height: 10)), style: s)
        state.annotations = [a1, a2, a3]
        state.selectedAnnotationIDs = [a1.id, a3.id]
        state.primarySelectionID = a3.id
        let h = TimelineTestHarness(state)
        state.deleteSelected()
        XCTAssertEqual(state.annotations.map(\.id), [a2.id])
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty)
        XCTAssertNil(state.primarySelectionID)
        h.undo()
        XCTAssertEqual(state.annotations.map(\.id), [a1.id, a2.id, a3.id])
    }

    func testDeleteSelected_emptySelection_isNoOp() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let s = Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        state.annotations = [Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)), style: s)]
        let h = TimelineTestHarness(state)
        state.deleteSelected()
        XCTAssertEqual(state.annotations.count, 1)
        XCTAssertFalse(h.canUndo)   // no checkpoint recorded
    }

    func testToolSwitch_clearsMultiSelection() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.selectedAnnotationIDs = [UUID(), UUID()]
        state.primarySelectionID = state.selectedAnnotationIDs.first
        state.selectedTool = .arrow
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty)
        XCTAssertNil(state.primarySelectionID)
    }

    func testInsertPasted_appendsSelectsAndUndoRemoves() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let s = Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        let existing = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)), style: s)
        state.annotations = [existing]
        let pasted = Annotation(geometry: .rectangle(rect: CGRect(x: 5, y: 5, width: 10, height: 10)), style: s)
        let h = TimelineTestHarness(state)
        state.insertPasted([pasted])
        XCTAssertEqual(state.annotations.map(\.id), [existing.id, pasted.id])
        XCTAssertEqual(state.selectedAnnotationIDs, [pasted.id])
        XCTAssertEqual(state.primarySelectionID, pasted.id)
        h.undo()
        XCTAssertEqual(state.annotations.map(\.id), [existing.id])
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty)
        XCTAssertNil(state.primarySelectionID)
    }

    func testUndoAfterPaste_clearsDanglingSelection() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let s = Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        let existing = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)), style: s)
        state.annotations = [existing]
        let pasted = Annotation(geometry: .rectangle(rect: CGRect(x: 5, y: 5, width: 10, height: 10)), style: s)
        let h = TimelineTestHarness(state)
        state.insertPasted([pasted])
        // Selection now points at the pasted annotation.
        XCTAssertEqual(state.selectedAnnotationIDs, [pasted.id])
        h.undo()
        // Pasted annotation is gone, so selection must not dangle.
        XCTAssertEqual(state.annotations.map(\.id), [existing.id])
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty)
        XCTAssertNil(state.primarySelectionID)
    }

    func testUndoReconcilesPrimaryWhenSomeSelectedSurvive() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let s = Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        let existing = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)), style: s)
        state.annotations = [existing]
        let p1 = Annotation(geometry: .rectangle(rect: CGRect(x: 5, y: 5, width: 10, height: 10)), style: s)
        let p2 = Annotation(geometry: .rectangle(rect: CGRect(x: 9, y: 9, width: 10, height: 10)), style: s)
        let h = TimelineTestHarness(state)
        state.insertPasted([p1, p2])             // selection = {p1,p2}, primary = nil (multi)
        // Also select the pre-existing annotation so something survives the undo.
        state.selectedAnnotationIDs.insert(existing.id)
        state.primarySelectionID = p2.id         // primary is a pasted (soon-dead) id
        h.undo()                                 // removes p1,p2; keeps existing
        XCTAssertEqual(state.annotations.map(\.id), [existing.id])
        XCTAssertEqual(state.selectedAnnotationIDs, [existing.id])
        XCTAssertEqual(state.primarySelectionID, existing.id)   // repaired to a live member
    }

    func testRedoAfterUndoneDelete_doesNotDangle() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let s = Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        let a1 = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)), style: s)
        let a2 = Annotation(geometry: .rectangle(rect: CGRect(x: 20, y: 20, width: 10, height: 10)), style: s)
        state.annotations = [a1, a2]
        state.selectedAnnotationIDs = [a1.id]
        state.primarySelectionID = a1.id
        let h = TimelineTestHarness(state)
        state.deleteSelected()                   // removes a1, selection cleared
        h.undo()                                 // a1 back; selection still empty (not restored)
        // Now re-select a1, then redo the delete and confirm no dangling primary.
        state.selectedAnnotationIDs = [a1.id]
        state.primarySelectionID = a1.id
        h.redo()                                 // re-applies delete: a1 removed again
        XCTAssertEqual(state.annotations.map(\.id), [a2.id])
        XCTAssertFalse(state.selectedAnnotationIDs.contains(a1.id))
        if let p = state.primarySelectionID {
            XCTAssertTrue(state.annotations.map(\.id).contains(p))  // primary is always live
        }
    }

    func testSelectAll_multiple_selectsEveryAnnotation_noDefaultPrimary() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let s = Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        let a1 = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)), style: s)
        let a2 = Annotation(geometry: .rectangle(rect: CGRect(x: 20, y: 20, width: 10, height: 10)), style: s)
        let a3 = Annotation(geometry: .rectangle(rect: CGRect(x: 40, y: 40, width: 10, height: 10)), style: s)
        state.annotations = [a1, a2, a3]
        state.selectAll()
        XCTAssertEqual(state.selectedAnnotationIDs, [a1.id, a2.id, a3.id])
        // A multi-selection has no object highlighted by default.
        XCTAssertNil(state.primarySelectionID)
    }

    func testSelectAll_single_makesItPrimary() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let s = Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        let a1 = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)), style: s)
        state.annotations = [a1]
        state.selectAll()
        XCTAssertEqual(state.primarySelectionID, a1.id)
    }

    func testInsertPasted_multiple_noDefaultPrimary() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let s = Style(strokeColor: SerializableColor(.red), strokeWidth: 3)
        let p1 = Annotation(geometry: .rectangle(rect: CGRect(x: 5, y: 5, width: 10, height: 10)), style: s)
        let p2 = Annotation(geometry: .rectangle(rect: CGRect(x: 9, y: 9, width: 10, height: 10)), style: s)
        state.insertPasted([p1, p2])
        XCTAssertEqual(state.selectedAnnotationIDs, [p1.id, p2.id])
        XCTAssertNil(state.primarySelectionID)
    }

    func testSelectAll_emptyAnnotations_isNoOp() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.selectAll()
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty)
        XCTAssertNil(state.primarySelectionID)
    }
    func testUndoRedo_restoresSourceURL() {
        let a = URL(fileURLWithPath: "/tmp/Old Name.seal")
        let b = URL(fileURLWithPath: "/tmp/New Name.seal")
        let state = EditorState(sourceImage: makeImage(), sourceURL: a)
        let h = TimelineTestHarness(state)
        state.recordUndoCheckpoint()   // capture the pre-rename URL
        state.sourceURL = b            // "rename"
        h.undo()
        XCTAssertEqual(state.sourceURL, a, "undo should revert the rename")
        h.redo()
        XCTAssertEqual(state.sourceURL, b, "redo should re-apply the rename")
    }

    func testDefaultTool_isSelect() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        XCTAssertEqual(state.selectedTool, .select)
    }

    func test_hasEdits_freshStateIsFalse() {
        func img(_ w: Int, _ h: Int) -> CGImage {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let s = EditorState(sourceImage: img(20, 20), sourceURL: nil)
        XCTAssertFalse(s.hasEdits)
    }

    func test_hasEdits_trueForEachEdit() {
        func img(_ w: Int, _ h: Int) -> CGImage {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let a = EditorState(sourceImage: img(20, 20), sourceURL: nil)
        a.croppedRect = CGRect(x: 0, y: 0, width: 5, height: 5)
        XCTAssertTrue(a.hasEdits)

        let b = EditorState(sourceImage: img(20, 20), sourceURL: nil)
        b.focusRect = CGRect(x: 0, y: 0, width: 5, height: 5)
        XCTAssertTrue(b.hasEdits)

        let c = EditorState(sourceImage: img(20, 20), sourceURL: nil)
        c.backgroundFill = SerializableColor(r: 1, g: 1, b: 1, a: 1)
        XCTAssertTrue(c.hasEdits)

        let d = EditorState(sourceImage: img(20, 20), sourceURL: nil, enhancedImage: img(40, 40), showingEnhanced: true)
        XCTAssertTrue(d.hasEdits)

        // Resize active (pristineSource set) counts as an edit even with nothing else.
        let e = EditorState(sourceImage: img(40, 40), sourceURL: nil, pristineSource: img(20, 20))
        XCTAssertTrue(e.hasEdits)

        // Non-empty annotations.
        let f = EditorState(sourceImage: img(20, 20), sourceURL: nil)
        f.annotations = [
            Annotation(
                geometry: .rectangle(rect: CGRect(x: 1, y: 1, width: 2, height: 2)),
                style: Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1), strokeWidth: 2)
            )
        ]
        XCTAssertTrue(f.hasEdits)

        // Cutout base showing.
        let g = EditorState(sourceImage: img(20, 20), sourceURL: nil)
        g.cutoutImage = img(20, 20)
        g.showingCutout = true
        XCTAssertTrue(g.hasEdits)

        // Non-empty imageAssets.
        let h = EditorState(sourceImage: img(20, 20), sourceURL: nil)
        h.imageAssets = ["k": Data([1, 2, 3])]
        XCTAssertTrue(h.hasEdits)
    }
}
