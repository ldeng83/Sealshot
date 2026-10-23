import XCTest
@testable import Sealshot

/// Live Text orders lines block by block, so a selection or copy inside one
/// block (a column, a sidebar, a panel) doesn't pull in lines from other blocks
/// that happen to sit on the same rows.
final class TextBlockReadingOrderTests: XCTestCase {

    private func line(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.3,
                      h: CGFloat = 0.02) -> RecognizedLine {
        let box = CGRect(x: x, y: y, width: w, height: h)
        return RecognizedLine(text: s, box: box,
                              charBoxes: subdivideLineBox(box, count: s.count))
    }

    private func order(_ lines: [RecognizedLine]) -> [String] {
        RecognizedTextLayout.blockReadingOrder(lines).map(\.text)
    }

    func testTwoColumns_eachColumnIsContiguous() {
        let lines = [
            line("L1", x: 0.05, y: 0.10), line("R1", x: 0.60, y: 0.10),
            line("L2", x: 0.05, y: 0.13), line("R2", x: 0.60, y: 0.13),
            line("L3", x: 0.05, y: 0.16), line("R3", x: 0.60, y: 0.16),
        ]
        XCTAssertEqual(order(lines), ["L1", "L2", "L3", "R1", "R2", "R3"])
    }

    func testSidebarAndContent_selectionStaysInContent() {
        let lines = [
            line("Inbox", x: 0.02, y: 0.10, w: 0.12), line("Para 1", x: 0.30, y: 0.11, w: 0.6),
            line("Sent", x: 0.02, y: 0.13, w: 0.12), line("Para 2", x: 0.30, y: 0.14, w: 0.6),
            line("Trash", x: 0.02, y: 0.16, w: 0.12), line("Para 3", x: 0.30, y: 0.17, w: 0.6),
        ]
        let layout = RecognizedTextLayout(lines: RecognizedTextLayout.blockReadingOrder(lines))
        let first = layout.lines.firstIndex { $0.text == "Para 1" }!
        let last = layout.lines.firstIndex { $0.text == "Para 3" }!
        let sel = TextSelection(anchor: TextPosition(line: first, char: 0),
                                focus: TextPosition(line: last, char: 6))
        XCTAssertEqual(layout.text(for: sel), "Para 1\nPara 2\nPara 3")
    }

    func testSingleColumn_isTopToBottom() {
        let lines = [line("C", x: 0.1, y: 0.16), line("A", x: 0.1, y: 0.10), line("B", x: 0.1, y: 0.13)]
        XCTAssertEqual(order(lines), ["A", "B", "C"])
    }

    /// Tightly spaced cells (a table, a label beside its value) are one block,
    /// so they keep row order rather than being read column by column.
    func testTightTableKeepsRowOrder() {
        let lines = [
            line("Name", x: 0.10, y: 0.10, w: 0.10), line("Ada", x: 0.22, y: 0.10, w: 0.10),
            line("Role", x: 0.10, y: 0.13, w: 0.10), line("Eng", x: 0.22, y: 0.13, w: 0.10),
        ]
        XCTAssertEqual(order(lines), ["Name", "Ada", "Role", "Eng"])
    }

    /// Blocks far apart vertically in the same column are still read top first.
    func testSeparatedBlocksInOneColumn_readTopFirst() {
        let lines = [
            line("Footer", x: 0.1, y: 0.90),
            line("Body 1", x: 0.1, y: 0.40), line("Body 2", x: 0.1, y: 0.43),
            line("Title", x: 0.1, y: 0.10, h: 0.05),
        ]
        XCTAssertEqual(order(lines), ["Title", "Body 1", "Body 2", "Footer"])
    }
}
