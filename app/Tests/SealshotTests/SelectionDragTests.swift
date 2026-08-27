import XCTest
import CoreGraphics
@testable import Sealshot

/// Drag-to-select should be character-INCLUSIVE at both ends: the glyph under
/// where you press AND the glyph under where you release are both selected.
/// (Nearest-caret rounding dropped the first character — "abcde" started at "b".)
final class SelectionDragTests: XCTestCase {

    private func line(_ text: String) -> RecognizedLine {
        let box = CGRect(x: 0, y: 0.4, width: 1, height: 0.1)
        return RecognizedLine(
            text: text, box: box,
            charBoxes: subdivideLineBox(box, count: text.count),
            quad: TextQuad(topLeft: CGPoint(x: 0, y: 0.4), topRight: CGPoint(x: 1, y: 0.4),
                           bottomRight: CGPoint(x: 1, y: 0.5), bottomLeft: CGPoint(x: 0, y: 0.5)))
    }

    func testDragFromBeforeFirstCharIncludesIt() {
        // The reported bug: press right before 'a', drag onto 'b' → "ab", not "b".
        let layout = RecognizedTextLayout(lines: [line("abcde")])
        let sel = layout.dragSelection(from: CGPoint(x: 0.01, y: 0.45),
                                       to: CGPoint(x: 0.35, y: 0.45))   // 0.35 → glyph 1 ('b')
        XCTAssertEqual(layout.text(for: sel), "ab")
    }

    func testDragIncludesGlyphUnderRelease() {
        let layout = RecognizedTextLayout(lines: [line("abcde")])
        let sel = layout.dragSelection(from: CGPoint(x: 0.02, y: 0.45),
                                       to: CGPoint(x: 0.5, y: 0.45))    // 0.5 → glyph 2 ('c')
        XCTAssertEqual(layout.text(for: sel), "abc")
    }

    func testDragReversedSelectsSameRange() {
        let layout = RecognizedTextLayout(lines: [line("abcde")])
        let sel = layout.dragSelection(from: CGPoint(x: 0.5, y: 0.45),
                                       to: CGPoint(x: 0.0, y: 0.45))
        XCTAssertEqual(layout.text(for: sel), "abc")
    }

    func testDragToLastCharIncludesIt() {
        let layout = RecognizedTextLayout(lines: [line("abcde")])
        let sel = layout.dragSelection(from: CGPoint(x: 0.0, y: 0.45),
                                       to: CGPoint(x: 0.99, y: 0.45))   // glyph 4 ('e')
        XCTAssertEqual(layout.text(for: sel), "abcde")
    }
}
