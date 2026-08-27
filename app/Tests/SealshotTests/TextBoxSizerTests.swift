import XCTest
import AppKit
@testable import Sealshot

final class TextBoxSizerTests: XCTestCase {
    private func run(_ text: String, size: CGFloat = 18) -> TextRun {
        TextRun(text: text, color: SerializableColor(.black), fontSize: size, isBold: false)
    }
    private func oneLineHeight(_ size: CGFloat = 18) -> CGFloat {
        textBoxHeight(runs: [run("M", size: size)], width: 10_000)
    }

    @MainActor
    private func makeEditorState() -> EditorState {
        let size = CGSize(width: 8, height: 8)
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.white.set(); NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill(); img.unlockFocus()
        let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return EditorState(sourceImage: cg, sourceURL: nil)
    }

    @MainActor
    func testManualShrink_freezesLayoutWidth() {
        let s = makeEditorState()
        let runs = [TextRun(text: "hello world", color: SerializableColor(.black), fontSize: 18, isBold: false)]
        let a = Annotation(geometry: .text(rect: CGRect(x: 0, y: 0, width: 200, height: 30), runs: runs),
                           style: Style(strokeColor: SerializableColor(.black), strokeWidth: 0))
        s.annotations = [a]
        s.beginTextBoxResize(id: a.id)
        // simulate the drag result: rect narrowed to 80
        if case let .text(_, r) = s.annotations[0].geometry {
            s.annotations[0].geometry = .text(rect: CGRect(x: 0, y: 0, width: 80, height: 30), runs: r)
        }
        s.endTextBoxResize(id: a.id)
        XCTAssertEqual(s.annotations[0].style.textLayoutWidth ?? -1, 200, accuracy: 0.5,
                       "shrinking must keep the original wrap width (mask semantics)")
    }

    @MainActor
    func testManualEnlargeBeyondLayout_adoptsNewWidth() {
        let s = makeEditorState()
        var style = Style(strokeColor: SerializableColor(.black), strokeWidth: 0)
        style.textLayoutWidth = 200
        let runs = [TextRun(text: "hello", color: SerializableColor(.black), fontSize: 18, isBold: false)]
        let a = Annotation(geometry: .text(rect: CGRect(x: 0, y: 0, width: 80, height: 30), runs: runs),
                           style: style)
        s.annotations = [a]
        s.beginTextBoxResize(id: a.id)
        if case let .text(_, r) = s.annotations[0].geometry {
            s.annotations[0].geometry = .text(rect: CGRect(x: 0, y: 0, width: 260, height: 30), runs: r)
        }
        s.endTextBoxResize(id: a.id)
        XCTAssertNil(s.annotations[0].style.textLayoutWidth,
                     "growing past the layout width re-couples mask and layout")
    }

    func testOneRowBox_typingGrowsWidth_neverWraps() {
        let h = oneLineHeight()
        let rect = CGRect(x: 0, y: 0, width: 20, height: h)   // one-char click box
        let out = TextBoxSizer.grownBox(runs: [run("hello world hello")], lineSpacing: 0,
                                        rect: rect, layoutWidth: rect.width, rectFollowsWidth: true)
        XCTAssertEqual(out.rect.height, h, accuracy: 0.5, "no room for a 2nd row → height stays")
        XCTAssertGreaterThan(out.layoutWidth, 100, "width must follow the typing")
        XCTAssertEqual(out.rect.width, out.layoutWidth, accuracy: 0.5, "rect follows layout growth")
        XCTAssertLessThanOrEqual(textBoxHeight(runs: [run("hello world hello")], width: out.layoutWidth),
                                 out.rect.height + 0.5, "text must fit the row")
    }

    func testTallBox_wrapsWhileHeightAllows() {
        let h = oneLineHeight()
        let rect = CGRect(x: 0, y: 0, width: 120, height: h * 3 + 2)   // room for 3 rows
        let out = TextBoxSizer.grownBox(runs: [run("aaa bbb ccc ddd")], lineSpacing: 0,
                                        rect: rect, layoutWidth: 120, rectFollowsWidth: true)
        XCTAssertEqual(out.layoutWidth, 120, accuracy: 0.5,
                       "text that wraps within the height must not widen the box")
        XCTAssertEqual(out.rect, rect, "rect unchanged while wrapping fits")
    }

    func testTallBoxFull_growsWidth_notHeight() {
        let h = oneLineHeight()
        let rect = CGRect(x: 0, y: 0, width: 60, height: h * 2 + 2)    // room for 2 rows
        let long = run("aaaa bbbb cccc dddd eeee ffff gggg hhhh")
        let out = TextBoxSizer.grownBox(runs: [long], lineSpacing: 0,
                                        rect: rect, layoutWidth: 60, rectFollowsWidth: true)
        XCTAssertEqual(out.rect.height, rect.height, accuracy: 0.5,
                       "soft overflow must NOT grow height (Enter is how you add rows)")
        XCTAssertGreaterThan(out.layoutWidth, 60, "…the width grows instead")
        XCTAssertLessThanOrEqual(textBoxHeight(runs: [long], width: out.layoutWidth),
                                 rect.height + 0.5)
    }

    func testEnterGrowsHeight() {
        let h = oneLineHeight()
        let rect = CGRect(x: 0, y: 0, width: 120, height: h)
        let out = TextBoxSizer.grownBox(runs: [run("one\ntwo\nthree")], lineSpacing: 0,
                                        rect: rect, layoutWidth: 120, rectFollowsWidth: true)
        XCTAssertGreaterThanOrEqual(out.rect.height, h * 3 - 0.5,
                                    "hard newlines must grow the height")
        XCTAssertEqual(out.layoutWidth, 120, accuracy: 0.5)
    }

    func testGrowOnly_shorterTextKeepsBox() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 90)
        let out = TextBoxSizer.grownBox(runs: [run("x")], lineSpacing: 0,
                                        rect: rect, layoutWidth: 300, rectFollowsWidth: true)
        XCTAssertEqual(out.rect, rect, "deleting text never shrinks the box")
        XCTAssertEqual(out.layoutWidth, 300, accuracy: 0.5)
    }

    func testDecoupledBox_layoutGrows_maskStays() {
        let h = oneLineHeight()
        let rect = CGRect(x: 0, y: 0, width: 40, height: h)            // shrunk mask
        let out = TextBoxSizer.grownBox(runs: [run("hello world hello")], lineSpacing: 0,
                                        rect: rect, layoutWidth: 200, rectFollowsWidth: false)
        XCTAssertEqual(out.rect.width, 40, accuracy: 0.5, "manually shrunk mask must not re-grow")
        XCTAssertGreaterThanOrEqual(out.layoutWidth, 200)
    }

    func testClickCreation_isOneCharacterCell() {
        let style = Style(strokeColor: SerializableColor(.black), strokeWidth: 0, fontSize: 24)
        let r = TextBoxSizer.creationRect(clickAt: CGPoint(x: 50, y: 60),
                                          draggedRect: .zero, isClick: true, style: style)
        let probe = TextRun(text: "M", color: SerializableColor(.black), fontSize: 24, isBold: false)
        let charW = ceil(attributedString(for: [probe], opacity: 1).size().width)
        XCTAssertEqual(r.origin, CGPoint(x: 50, y: 60))
        // One letter wide PLUS the box's horizontal padding on both sides.
        XCTAssertEqual(r.width, charW + 2 * textBoxHPadding, accuracy: 1.0,
                       "click box = one letter wide + H padding at current font")
        XCTAssertEqual(r.height, textBoxHeight(runs: [probe], width: 10_000), accuracy: 1.0,
                       "…and one letter tall")
    }

    /// Pins the `SelectionChromeOverlay` live manual-resize drag-path contract:
    /// once `beginTextBoxResize` has frozen the layout width, the per-tick
    /// `clampTextHeight` call must pass that frozen width via `layoutWidth:`,
    /// NOT rely on the default (which measures wrap at the live dragged
    /// rect's width). Otherwise shrinking a one-row box narrower mid-drag
    /// re-wraps the text to more rows and grows the box height, showing
    /// empty mask space during a sideways shrink — violating the mask model
    /// ("shrink hides text, never re-wraps").
    func testLiveResizeClamp_measuresAtFrozenLayoutWidth_notDraggedWidth() {
        let runs = [run("hello world hello")]
        let oneRowHeight = textBoxHeight(runs: runs, width: 200)
        let draggedRect = CGRect(x: 0, y: 0, width: 80, height: oneRowHeight)

        // Fixed behavior: pass the frozen layout width (200, from
        // beginTextBoxResize) explicitly — the one-row height must hold even
        // though the live rect narrowed to 80.
        let fixed = clampTextHeight(rect: draggedRect, runs: runs, anchorBottom: false,
                                    layoutWidth: 200)
        XCTAssertEqual(fixed.height, oneRowHeight, accuracy: 0.5,
                       "shrinking below the frozen layout width must clip text, not re-wrap+grow")
        XCTAssertEqual(fixed.width, 80, accuracy: 0.5, "width follows the drag")

        // Sanity check on the bug this pins against: omitting `layoutWidth`
        // measures wrap at the narrower dragged width and grows the box.
        let buggy = clampTextHeight(rect: draggedRect, runs: runs, anchorBottom: false)
        XCTAssertGreaterThan(buggy.height, oneRowHeight + 0.5,
                             "sanity: the un-pinned default measures more rows at the narrow width")
    }

    func testDragCreation_keepsDraggedSize() {
        let style = Style(strokeColor: SerializableColor(.black), strokeWidth: 0, fontSize: 18)
        let dragged = CGRect(x: 10, y: 20, width: 200, height: 90)
        let r = TextBoxSizer.creationRect(clickAt: dragged.origin,
                                          draggedRect: dragged, isClick: false, style: style)
        XCTAssertEqual(r, dragged, "dragged box keeps BOTH its width and height (wrap capacity)")
    }

    /// A deliberately height-shrunk mask must survive style edits: the
    /// grow-only clamp exists to keep NEW growth from clipping a fitting box,
    /// never to "repair" a box whose text already overflowed before the edit.
    @MainActor
    func testStyleEditOnHeightShrunkBox_doesNotRegrow() {
        let s = makeEditorState()
        let runs = [TextRun(text: "one two three four five six seven eight",
                            color: SerializableColor(.black), fontSize: 18, isBold: false)]
        let oneRow = textBoxHeight(runs: runs, width: 10_000)
        let rect = CGRect(x: 0, y: 0, width: 120, height: oneRow)   // multi-row content, one-row mask
        let a = Annotation(geometry: .text(rect: rect, runs: runs),
                           style: Style(strokeColor: SerializableColor(.black), strokeWidth: 0))
        s.annotations = [a]

        s.updateTextBoxStyle(id: a.id) { $0.lineSpacing = 6 }
        if case let .text(r1, _) = s.annotations[0].geometry {
            XCTAssertEqual(r1.height, oneRow, accuracy: 0.5,
                           "paragraph-style edit must not re-grow a shrunk mask")
        } else { XCTFail("geometry changed kind") }

        s.updateTextRuns(id: a.id) { $0[0].fontSize = 40 }
        if case let .text(r2, _) = s.annotations[0].geometry {
            XCTAssertEqual(r2.height, oneRow, accuracy: 0.5,
                           "font-size edit must not re-grow a shrunk mask")
        } else { XCTFail("geometry changed kind") }

        s.updateStyle(id: a.id) { $0.lineSpacing = 12 }
        if case let .text(r3, _) = s.annotations[0].geometry {
            XCTAssertEqual(r3.height, oneRow, accuracy: 0.5,
                           "generic style edit must not re-grow a shrunk mask")
        } else { XCTFail("geometry changed kind") }
    }

    /// Q4 regression guard: a box whose text FIT before the edit still grows
    /// so a bigger font never clips.
    @MainActor
    func testStyleEditOnFittingBox_stillGrowsToAvoidClipping() {
        let s = makeEditorState()
        let runs = [TextRun(text: "hello world", color: SerializableColor(.black),
                            fontSize: 18, isBold: false)]
        let fitting = textBoxHeight(runs: runs, width: 200)
        let rect = CGRect(x: 0, y: 0, width: 200, height: fitting)
        let a = Annotation(geometry: .text(rect: rect, runs: runs),
                           style: Style(strokeColor: SerializableColor(.black), strokeWidth: 0))
        s.annotations = [a]

        s.updateTextRuns(id: a.id) { $0[0].fontSize = 40 }
        if case let .text(r, newRuns) = s.annotations[0].geometry {
            XCTAssertGreaterThan(r.height, fitting + 1,
                                 "a fitting box must still grow for a bigger font")
            XCTAssertGreaterThanOrEqual(r.height,
                textBoxHeight(runs: newRuns, width: 200) - 0.5, "…enough to avoid clipping")
        } else { XCTFail("geometry changed kind") }
    }
}
