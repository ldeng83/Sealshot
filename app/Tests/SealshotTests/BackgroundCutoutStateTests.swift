import XCTest
@testable import Sealshot

/// Base-precedence + exclusivity rules for the background-removal cutout.
@MainActor
final class BackgroundCutoutStateTests: XCTestCase {

    private func img(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func test_displayBase_precedence_cutoutWinsOverEnhanced() {
        let state = EditorState(sourceImage: img(100, 80), sourceURL: nil,
                                enhancedImage: img(200, 160), showingEnhanced: true)
        XCTAssertEqual(state.displayBase.width, 200, "enhanced shows before any cutout")
        state.cutoutImage = img(100, 80)
        state.setShowingCutout(true)
        XCTAssertEqual(state.displayBase.width, 100, "cutout base takes over")
        XCTAssertFalse(state.showingEnhanced, "enabling the cutout hides the enhanced base")
        XCTAssertEqual(state.displayScale, 1.0, "cutout is a 1× base")
    }

    func test_setShowingCutout_requiresImage() {
        let state = EditorState(sourceImage: img(100, 80), sourceURL: nil)
        state.setShowingCutout(true)
        XCTAssertFalse(state.showingCutout, "no cutout image → flag can't turn on")
        XCTAssertEqual(state.displayBase.width, 100)
    }

    func test_persistedDisplayBase_followsCutout() {
        let state = EditorState(sourceImage: img(100, 80), sourceURL: nil)
        state.cutoutImage = img(100, 80)
        state.setShowingCutout(true)
        XCTAssertTrue(state.persistedDisplayBase === state.cutoutImage!)
    }
}

/// ⌘Z coverage: Remove Background toggles ride the undo/redo stacks.
@MainActor
final class BackgroundCutoutUndoTests: XCTestCase {

    private func img(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func test_undoRedo_stepsAcrossCutoutToggle() {
        let state = EditorState(sourceImage: img(100, 80), sourceURL: nil)
        state.cutoutImage = img(100, 80)
        let h = TimelineTestHarness(state)

        state.recordUndoCheckpoint(action: "Remove Background")
        state.setShowingCutout(true)
        XCTAssertTrue(state.showingCutout)

        XCTAssertEqual(h.undo(), "Remove Background")
        XCTAssertFalse(state.showingCutout, "undo restores the original background")

        XCTAssertEqual(h.redo(), "Remove Background")
        XCTAssertTrue(state.showingCutout, "redo re-applies the cutout")
    }

    func test_undoAcrossAnnotationEdit_preservesCutoutAtCheckpointTime() {
        let state = EditorState(sourceImage: img(100, 80), sourceURL: nil)
        state.cutoutImage = img(100, 80)
        state.setShowingCutout(true)
        let h = TimelineTestHarness(state)

        // Annotation edit while the cutout is shown…
        state.recordUndoCheckpoint(action: "Add Arrow")
        state.annotations.append(Annotation(
            geometry: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)),
            style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3)))
        // …then the user restores the background.
        state.recordUndoCheckpoint(action: "Restore Background")
        state.setShowingCutout(false)

        _ = h.undo()   // undo Restore Background
        XCTAssertTrue(state.showingCutout)
        _ = h.undo()   // undo Add Arrow — cutout was on at that checkpoint
        XCTAssertTrue(state.showingCutout)
        XCTAssertTrue(state.annotations.isEmpty)
    }

    func test_legacySnapshot_missingFlag_decodesToOriginalBackground() throws {
        // Persisted histories predating the field: nil → false on restore.
        let json = #"{"annotations":[],"croppedRect":null,"focusRect":null,"sourceURL":null}"#
        let snap = try JSONDecoder().decode(EditorSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.showingCutout)
    }
}
