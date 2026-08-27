import XCTest
import AppKit
@testable import Sealshot

/// The object right-click menu. Order is the macOS convention — clipboard
/// first, destructive Delete last — and Paste must reflect what is actually on
/// the clipboard, because the menu sets autoenablesItems = false and so gets
/// no automatic validation.
@MainActor
final class CanvasObjectMenuTests: XCTestCase {

    private func makeImage(width: Int = 400, height: Int = 300) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makeCanvas(with annotations: [Annotation]) -> (EditorCanvasView, EditorState) {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.annotations = annotations
        let canvas = EditorCanvasView(state: state)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        return (canvas, state)
    }

    private func rectAnnotation() -> Annotation {
        Annotation(id: UUID(),
                   geometry: .rectangle(rect: CGRect(x: 10, y: 10, width: 40, height: 30)),
                   style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3))
    }

    /// `EditorState.isFlippable` currently excludes only `.badge` (a mirrored
    /// step number reads wrong); text can be flipped like any other shape as
    /// of a deliberate later change, so badge is the real non-flippable case.
    private func badgeAnnotation() -> Annotation {
        Annotation(id: UUID(),
                   geometry: .badge(center: CGPoint(x: 30, y: 30), radius: 12),
                   style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3))
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    func testItemOrderMatchesTheMacOSConvention() {
        let shape = rectAnnotation()
        let (canvas, state) = makeCanvas(with: [shape])
        state.setSelection([shape.id], primary: shape.id)

        let menu = canvas.objectMenu(hitID: shape.id)

        XCTAssertEqual(titles(menu), [
            "Cut", "Copy", "Paste", "Duplicate", "---",
            "Bring to Front", "Bring Forward", "Send Backward", "Send to Back", "---",
            "Flip Horizontal", "Flip Vertical", "---",
            "Delete",
        ])
    }

    func testPasteIsDisabledWithAnEmptyClipboard() {
        NSPasteboard.general.clearContents()
        let shape = rectAnnotation()
        let (canvas, state) = makeCanvas(with: [shape])
        state.setSelection([shape.id], primary: shape.id)

        let menu = canvas.objectMenu(hitID: shape.id)
        let paste = menu.items.first { $0.title == "Paste" }

        XCTAssertEqual(paste?.isEnabled, false)
    }

    func testPasteIsEnabledWithAnAnnotationPayload() {
        let shape = rectAnnotation()
        AnnotationPasteboard.write(AnnotationClipboardPayload(annotations: [shape], assets: [:]))
        let (canvas, state) = makeCanvas(with: [shape])
        state.setSelection([shape.id], primary: shape.id)

        let menu = canvas.objectMenu(hitID: shape.id)
        let paste = menu.items.first { $0.title == "Paste" }

        XCTAssertEqual(paste?.isEnabled, true)
    }

    /// Badges never mirror (a flipped step number reads wrong), so the flip
    /// items are omitted entirely rather than shown disabled.
    func testFlipItemsAreAbsentForANonFlippableSelection() {
        let badge = badgeAnnotation()
        let (canvas, state) = makeCanvas(with: [badge])
        state.setSelection([badge.id], primary: badge.id)

        let menu = canvas.objectMenu(hitID: badge.id)

        XCTAssertFalse(titles(menu).contains("Flip Horizontal"))
        XCTAssertFalse(titles(menu).contains("Flip Vertical"))
        XCTAssertTrue(titles(menu).contains("Cut"), "the clipboard group still shows")
    }

    func testDeleteTitlePluralisesForAMultiSelection() {
        let a = rectAnnotation(), b = rectAnnotation()
        let (canvas, state) = makeCanvas(with: [a, b])
        state.setSelection([a.id, b.id], primary: nil)

        let menu = canvas.objectMenu(hitID: a.id)

        XCTAssertTrue(titles(menu).contains("Delete Objects"))
    }
}
