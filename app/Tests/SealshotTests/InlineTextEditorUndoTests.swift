import XCTest
@testable import Sealshot

/// Smart undo while editing a text annotation: AppKit coalesces an entire
/// uninterrupted typing burst into ONE undo group, so ⌘Z nuked the whole
/// paragraph. The inline editor must break coalescing at word boundaries and
/// typing pauses so ⌘Z peels back chunks like a modern text box.
@MainActor
final class InlineTextEditorUndoTests: XCTestCase {

    private func makeEditor() -> InlineTextEditor {
        let editor = InlineTextEditor()
        editor.configure(
            frame: NSRect(x: 0, y: 0, width: 300, height: 60),
            runs: [],
            defaultRun: TextRun(text: "", color: SerializableColor(r: 0, g: 0, b: 0, a: 1),
                                fontSize: 18, isBold: false),
            opacity: 1, scale: 1, wrapWidth: 300)
        return editor
    }

    /// Simulate real typing: one insertText per character, through the
    /// should/didChange path that registers undo, with a run-loop turn after
    /// each keystroke — real key events are separate run-loop events, and
    /// UndoManager's groupsByEvent needs the turn to close each event group.
    private func type(_ text: String, into editor: InlineTextEditor) {
        for ch in text {
            editor.textView.insertText(String(ch), replacementRange: editor.textView.selectedRange())
            RunLoop.main.run(until: Date())
        }
    }

    func testUndoPeelsWordChunks_notTheWholeText() {
        let editor = makeEditor()
        type("hello world", into: editor)
        XCTAssertEqual(editor.textView.string, "hello world")

        editor.performUndo()
        XCTAssertEqual(editor.textView.string, "hello ",
                       "first ⌘Z must peel the last word chunk, not the whole text")
        editor.performUndo()
        XCTAssertEqual(editor.textView.string, "",
                       "second ⌘Z removes the first chunk (word + its delimiter)")

        editor.performRedo()
        XCTAssertEqual(editor.textView.string, "hello ",
                       "⇧⌘Z restores chunks in the same granularity")
    }

    /// Field bug: after ⌘Z undid everything, typing was dead — the undo
    /// application itself re-entered the delegate and opened a rogue chunk
    /// group mid-undo, corrupting the undo manager's state.
    func testTypingStillWorksAfterUndoingToEmpty() {
        let editor = makeEditor()
        type("hello", into: editor)
        editor.performUndo()
        XCTAssertEqual(editor.textView.string, "")

        type("abc", into: editor)
        XCTAssertEqual(editor.textView.string, "abc",
                       "typing after undo-to-empty must still insert text")
        editor.performUndo()
        XCTAssertEqual(editor.textView.string, "",
                       "and the new text must be undoable")
    }

    /// Field bug: line⏎line⏎ then pause — ⌘Z appeared to do nothing. The
    /// chunk boundary sat BEFORE the delimiter, so the last chunk was a lone
    /// trailing newline whose undo is invisible. Chunks now close AFTER the
    /// delimiter (word+delimiter peel), and undo must stay visibly effective.
    func testNewlineChunks_undoPeelsWholeLines() {
        let editor = makeEditor()
        type("one\ntwo\n", into: editor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(editor.textView.string, "one\ntwo\n")

        editor.performUndo()
        XCTAssertEqual(editor.textView.string, "one\n",
                       "⌘Z must remove the last line including its newline")
        editor.performUndo()
        XCTAssertEqual(editor.textView.string, "",
                       "⌘Z again removes the first line")
    }

    func testTypingPauseStartsANewUndoChunk() {
        let editor = makeEditor()
        editor.typingChunkInterval = 0.05   // shrink the idle window for the test
        type("abc", into: editor)
        // Let the idle timer fire — a real pause between typing bursts.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        type("def", into: editor)
        XCTAssertEqual(editor.textView.string, "abcdef")

        editor.performUndo()
        XCTAssertEqual(editor.textView.string, "abc",
                       "⌘Z after a pause must only remove the burst typed since the pause")
    }
}
