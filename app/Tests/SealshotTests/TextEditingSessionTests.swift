import XCTest
import AppKit
@testable import Sealshot

/// Guards the live text-styling panel against rebuilding itself while the user
/// is actively dragging a control. A style *apply* must not bump `epoch` (which
/// drives the sidebar rebuild) — only a *selection* change should. Otherwise a
/// font-size slider drag tears its own NSSlider out of the view tree mid-drag
/// and the value snaps to a track extreme.
final class TextEditingSessionTests: XCTestCase {

    @MainActor
    private func makeSession(text: String) -> (InlineTextEditor, TextEditingSession) {
        let editor = InlineTextEditor()
        let run = TextRun(text: text, color: SerializableColor(r: 0, g: 0, b: 0, a: 1),
                          fontSize: 18, isBold: false)
        editor.configure(frame: NSRect(x: 0, y: 0, width: 200, height: 50),
                         runs: [run], defaultRun: run, opacity: 1, scale: 1, wrapWidth: 200)
        let session = TextEditingSession(editor: editor)
        editor.onSelectionChange = { [weak session] in session?.refresh() }
        return (editor, session)
    }

    @MainActor
    func test_applyFontSize_doesNotRebuildPanel() {
        let (editor, session) = makeSession(text: "Hello")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 5))
        let before = session.epoch
        session.applyFontSize(40)
        XCTAssertEqual(session.epoch, before,
                       "applying a font size must not bump epoch (no mid-drag panel rebuild)")
        XCTAssertEqual(editor.selectionFontSize ?? 0, 40, accuracy: 0.01)
    }

    @MainActor
    func test_applyColorAndBold_doNotRebuildPanel() {
        let (editor, session) = makeSession(text: "Hello")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 5))
        let before = session.epoch
        session.applyColor(.red)
        session.setBold(true)
        XCTAssertEqual(session.epoch, before,
                       "applying color/bold must not bump epoch (no panel rebuild)")
    }

    @MainActor
    func test_selectionHighlight_keepsGlyphColorVisible() {
        let editor = InlineTextEditor()
        let attrs = editor.textView.selectedTextAttributes
        // No foreground override — selected glyphs keep their own color.
        XCTAssertNil(attrs[.foregroundColor],
                     "selection must not override foreground color")
        // Selection background is translucent so the color shows through.
        let bg = attrs[.backgroundColor] as? NSColor
        XCTAssertNotNil(bg)
        XCTAssertLessThan(bg!.alphaComponent, 1.0,
                          "selection background must be translucent")
    }

    @MainActor
    func test_selectionChange_rebuildsPanel() {
        let (editor, session) = makeSession(text: "Hello")
        let before = session.epoch
        editor.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification))
        XCTAssertGreaterThan(session.epoch, before,
                             "a selection change must bump epoch so the panel refreshes its readout")
    }
}
