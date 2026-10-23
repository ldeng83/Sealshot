import XCTest
import AppKit
@testable import Sealshot

/// Canvas-level behavior of a text box while it is being typed: Esc and the
/// box's resize dots.
@MainActor
final class InlineTextEditingCanvasTests: XCTestCase {

    private func makeImage(_ w: Int = 400, _ h: Int = 300) -> CGImage {
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makeCanvas() -> (EditorState, EditorCanvasView) {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        return (state, EditorCanvasView(state: state))
    }

    private func run(_ text: String) -> TextRun {
        TextRun(text: text, color: SerializableColor(.black), fontSize: 18, isBold: false)
    }

    private func escape() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\u{1b}",
                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }

    // MARK: - Esc

    /// Esc on a typed box lands where one Esc lands for a just-drawn shape:
    /// committed, nothing selected, tool unchanged.
    func testEscAfterTyping_commitsAndDeselects() {
        let (state, canvas) = makeCanvas()
        state.userSelectedTool(.text)
        canvas.beginTextEditing(rect: CGRect(x: 20, y: 20, width: 200, height: 30), existingID: nil,
                                initialRuns: [run("hello")], style: textCreationStyle(state: state))
        XCTAssertTrue(canvas.isEditingText)

        XCTAssertTrue(canvas.handleKeyWhileEditingText(escape()), "Esc is consumed while typing")

        XCTAssertFalse(canvas.isEditingText)
        XCTAssertEqual(state.annotations.count, 1, "the typed text is kept")
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty, "…and nothing is left selected")
        XCTAssertEqual(state.selectedTool, .text, "the tool stays, like after drawing a shape")
        XCTAssertNil(state.editingTextBoxRect)
    }

    /// After the Esc commit the CANVAS must hold focus, or the next Esc never
    /// reaches its keyDown and Esc → Info does nothing.
    func testEscCommit_returnsFocusToCanvas_soNextEscGoesToInfo() {
        let (state, canvas) = makeCanvas()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(canvas)
        state.userSelectedTool(.text)
        canvas.beginTextEditing(rect: CGRect(x: 20, y: 20, width: 200, height: 30), existingID: nil,
                                initialRuns: [run("hello")], style: textCreationStyle(state: state))
        XCTAssertTrue(window.firstResponder is NSTextView, "typing goes to the inline text view")

        _ = canvas.handleKeyWhileEditingText(escape())
        XCTAssertTrue(window.firstResponder === canvas, "focus returns to the canvas, not the window")

        canvas.keyDown(with: escape())
        XCTAssertEqual(state.sidebarPanelMode, .info, "second Esc shows the Info tab")
        XCTAssertEqual(state.selectedTool, .select)
    }

    func testEscReEditingExistingBox_deselectsIt() {
        let (state, canvas) = makeCanvas()
        let box = Annotation(geometry: .text(rect: CGRect(x: 20, y: 20, width: 200, height: 30),
                                             runs: [run("hello")]),
                             style: textCreationStyle(state: state))
        state.annotations = [box]
        state.selectOnly(box.id)
        canvas.beginTextEditing(rect: CGRect(x: 20, y: 20, width: 200, height: 30), existingID: box.id,
                                initialRuns: [run("hello")], style: box.style)

        _ = canvas.handleKeyWhileEditingText(escape())

        XCTAssertEqual(state.annotations.count, 1)
        XCTAssertTrue(state.selectedAnnotationIDs.isEmpty)
    }

    func testEscOnEmptyNewBox_stillDiscardsIt() {
        let (state, canvas) = makeCanvas()
        canvas.beginTextEditing(rect: CGRect(x: 20, y: 20, width: 200, height: 30), existingID: nil,
                                initialRuns: [], style: textCreationStyle(state: state))
        _ = canvas.handleKeyWhileEditingText(escape())
        XCTAssertTrue(state.annotations.isEmpty)
    }

    // MARK: - Resize while typing

    func testEditingBoxRectIsPublishedWhileTyping() {
        let (state, canvas) = makeCanvas()
        let rect = CGRect(x: 20, y: 20, width: 200, height: 30)
        canvas.beginTextEditing(rect: rect, existingID: nil,
                                initialRuns: [run("hello")], style: textCreationStyle(state: state))
        XCTAssertEqual(state.editingTextBoxRect, rect, "the overlay needs the rect to hit-test the dots")
    }

    func testResizeWhileTyping_rewrapsAndKeepsEditing() throws {
        let (state, canvas) = makeCanvas()
        let text = "the quick brown fox jumps over the lazy dog"
        canvas.beginTextEditing(rect: CGRect(x: 20, y: 20, width: 360, height: 30), existingID: nil,
                                initialRuns: [run(text)], style: textCreationStyle(state: state))

        canvas.resizeEditingTextBox(to: CGRect(x: 20, y: 20, width: 100, height: 30), keepBottom: false)

        XCTAssertTrue(canvas.isEditingText, "a resize drag must not end the edit")
        let live = try XCTUnwrap(state.editingTextBoxRect)
        XCTAssertEqual(live.width, 100, "width follows the drag")
        XCTAssertGreaterThan(live.height, 30, "narrower box grows taller so wrapped lines stay visible")

        _ = canvas.handleKeyWhileEditingText(escape())
        guard case let .text(committed, runs) = state.annotations.first?.geometry else {
            return XCTFail("text box not committed")
        }
        XCTAssertEqual(runs.map(\.text).joined(), text)
        XCTAssertEqual(committed.width, 100)
        XCTAssertNil(state.annotations[0].style.textLayoutWidth,
                     "the resized box rewrapped, so layout and box width agree (no mask)")
    }
}
