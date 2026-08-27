import XCTest
@testable import Sealshot

final class TextSelectionTests: XCTestCase {
    func testPositionComparable() {
        XCTAssertLessThan(TextPosition(line: 0, char: 3), TextPosition(line: 1, char: 0))
        XCTAssertLessThan(TextPosition(line: 2, char: 1), TextPosition(line: 2, char: 4))
        XCTAssertEqual(TextPosition(line: 1, char: 2), TextPosition(line: 1, char: 2))
    }

    func testOrderedNormalizesReversedAnchorFocus() {
        let sel = TextSelection(anchor: TextPosition(line: 3, char: 2),
                                focus: TextPosition(line: 1, char: 5))
        XCTAssertEqual(sel.ordered.start, TextPosition(line: 1, char: 5))
        XCTAssertEqual(sel.ordered.end, TextPosition(line: 3, char: 2))
    }

    func testIsEmptyWhenStartEqualsEnd() {
        let p = TextPosition(line: 0, char: 0)
        XCTAssertTrue(TextSelection(anchor: p, focus: p).isEmpty)
        XCTAssertFalse(TextSelection(anchor: p, focus: TextPosition(line: 0, char: 1)).isEmpty)
    }

    func testCollapsedFactory() {
        let p = TextPosition(line: 2, char: 4)
        let sel = TextSelection.collapsed(at: p)
        XCTAssertTrue(sel.isEmpty)
        XCTAssertEqual(sel.ordered.start, p)
    }

    func testOrderedLeavesForwardSelectionUnchanged() {
        let sel = TextSelection(anchor: TextPosition(line: 1, char: 0),
                                focus: TextPosition(line: 2, char: 3))
        XCTAssertEqual(sel.ordered.start, TextPosition(line: 1, char: 0))
        XCTAssertEqual(sel.ordered.end, TextPosition(line: 2, char: 3))
    }
}
