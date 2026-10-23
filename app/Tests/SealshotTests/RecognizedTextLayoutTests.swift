import XCTest
@testable import Sealshot

final class RecognizedTextLayoutTests: XCTestCase {

    /// Build a line whose i-th char box is (x: i*0.1, y: top, w: 0.1, h: 0.2).
    private func line(_ s: String, top: CGFloat) -> RecognizedLine {
        let boxes = (0..<s.count).map { i in
            CGRect(x: CGFloat(i) * 0.1, y: top, width: 0.1, height: 0.2)
        }
        let bounding = CGRect(x: 0, y: top, width: CGFloat(s.count) * 0.1, height: 0.2)
        return RecognizedLine(text: s, box: bounding, charBoxes: boxes)
    }

    private func layout() -> RecognizedTextLayout {
        RecognizedTextLayout(lines: [line("ABC", top: 0.0), line("XYZ", top: 0.3)])
    }

    func testPositionAtPointPicksLineAndCaret() {
        let p = layout().position(at: CGPoint(x: 0.12, y: 0.1))
        XCTAssertEqual(p, TextPosition(line: 0, char: 1))
        let q = layout().position(at: CGPoint(x: 0.95, y: 0.4))
        XCTAssertEqual(q, TextPosition(line: 1, char: 3))
    }

    func testTextForSelectionSameLine() {
        let sel = TextSelection(anchor: TextPosition(line: 0, char: 0),
                                focus: TextPosition(line: 0, char: 2))
        XCTAssertEqual(layout().text(for: sel), "AB")
    }

    func testTextForSelectionAcrossLines() {
        let sel = TextSelection(anchor: TextPosition(line: 0, char: 1),
                                focus: TextPosition(line: 1, char: 2))
        XCTAssertEqual(layout().text(for: sel), "BC\nXY")
    }

    func testPositionPicksLineByXInSameRow() {
        // Two lines sharing the same Y band (a two-column row): "LEFT" on the
        // left, "RIGHT" on the right. A click on the right column must land on
        // the right line, not the first one in reading order.
        let left = RecognizedLine(
            text: "LEFT",
            box: CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.1),
            charBoxes: (0..<4).map { CGRect(x: CGFloat($0) * 0.05, y: 0, width: 0.05, height: 0.1) }
        )
        let right = RecognizedLine(
            text: "RIGHT",
            box: CGRect(x: 0.6, y: 0.0, width: 0.25, height: 0.1),
            charBoxes: (0..<5).map { CGRect(x: 0.6 + CGFloat($0) * 0.05, y: 0, width: 0.05, height: 0.1) }
        )
        let lay = RecognizedTextLayout(lines: [left, right])
        XCTAssertEqual(lay.position(at: CGPoint(x: 0.05, y: 0.05)).line, 0)
        XCTAssertEqual(lay.position(at: CGPoint(x: 0.70, y: 0.05)).line, 1)
    }

    func testBoxesForSelectionOnePerCoveredLine() {
        let sel = TextSelection(anchor: TextPosition(line: 0, char: 1),
                                focus: TextPosition(line: 1, char: 2))
        let boxes = layout().boxes(for: sel)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes[0].minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(boxes[0].width, 0.2, accuracy: 0.0001)
        XCTAssertEqual(boxes[1].minX, 0.0, accuracy: 0.0001)
        XCTAssertEqual(boxes[1].width, 0.2, accuracy: 0.0001)
    }

    func testWordRangeAtPoint() {
        let l = RecognizedLine(
            text: "hi bye",
            box: CGRect(x: 0, y: 0, width: 0.6, height: 0.2),
            charBoxes: (0..<6).map { CGRect(x: CGFloat($0) * 0.1, y: 0, width: 0.1, height: 0.2) }
        )
        let lay = RecognizedTextLayout(lines: [l])
        let sel = lay.wordRange(at: CGPoint(x: 0.45, y: 0.1))
        XCTAssertEqual(sel?.ordered.start, TextPosition(line: 0, char: 3))
        XCTAssertEqual(sel?.ordered.end, TextPosition(line: 0, char: 6))
    }

    func testFullSelectionCoversEverything() {
        let sel = layout().fullSelection
        XCTAssertEqual(layout().text(for: sel), "ABC\nXYZ")
    }

    func testIsEmptyLayout() {
        XCTAssertTrue(RecognizedTextLayout(lines: []).isEmpty)
        XCTAssertFalse(layout().isEmpty)
    }

    func testWordRangeOnWhitespaceReturnsNil() {
        let l = RecognizedLine(
            text: "a b",
            box: CGRect(x: 0, y: 0, width: 0.3, height: 0.2),
            charBoxes: (0..<3).map { CGRect(x: CGFloat($0) * 0.1, y: 0, width: 0.1, height: 0.2) }
        )
        let lay = RecognizedTextLayout(lines: [l])
        // x=0.11 lands on the space (char index 1) -> nil.
        XCTAssertNil(lay.wordRange(at: CGPoint(x: 0.11, y: 0.1)))
    }

    // MARK: Highlight follows the character boxes

    /// "ill WWW": narrow glyphs then wide ones, as proportional text measures.
    /// An even split of the line (1/7 per character) would put the word "WWW"'s
    /// highlight about a character too far left; its boxes say where it is.
    private func proportionalLine() -> RecognizedLine {
        let widths: [CGFloat] = [0.03, 0.03, 0.03, 0.06, 0.25, 0.25, 0.25]
        var x: CGFloat = 0.05
        let boxes = widths.map { w -> CGRect in
            defer { x += w }
            return CGRect(x: x, y: 0.4, width: w, height: 0.1)
        }
        let box = CGRect(x: 0.05, y: 0.4, width: 0.9, height: 0.1)
        let quad = TextQuad(topLeft: CGPoint(x: 0.05, y: 0.4), topRight: CGPoint(x: 0.95, y: 0.4),
                            bottomRight: CGPoint(x: 0.95, y: 0.5), bottomLeft: CGPoint(x: 0.05, y: 0.5))
        return RecognizedLine(text: "ill WWW", box: box, charBoxes: boxes, quad: quad)
    }

    func testWordHighlightQuadMatchesItsCharacterBoxes() {
        let lay = RecognizedTextLayout(lines: [proportionalLine()])
        let word = TextSelection(anchor: TextPosition(line: 0, char: 4),
                                 focus: TextPosition(line: 0, char: 7))
        let q = try! XCTUnwrap(lay.quads(for: word).first)
        XCTAssertEqual(q.topLeft.x, 0.20, accuracy: 1e-6, "starts at the first W")
        XCTAssertEqual(q.topRight.x, 0.95, accuracy: 1e-6, "ends at the last W")
    }

    func testNarrowWordHighlightDoesNotSpillIntoNeighbour() {
        let lay = RecognizedTextLayout(lines: [proportionalLine()])
        let word = TextSelection(anchor: TextPosition(line: 0, char: 0),
                                 focus: TextPosition(line: 0, char: 3))
        let q = try! XCTUnwrap(lay.quads(for: word).first)
        XCTAssertEqual(q.topLeft.x, 0.05, accuracy: 1e-6)
        XCTAssertEqual(q.topRight.x, 0.14, accuracy: 1e-6, "ends after the last l, not into the space")
    }
}
