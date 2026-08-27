import XCTest
@testable import Sealshot

@MainActor
final class SpanRectsTests: XCTestCase {
    /// Each line gets a distinct y so per-line rects are distinguishable.
    private func layout(_ texts: [String]) -> RecognizedTextLayout {
        var lines: [RecognizedLine] = []
        for (i, text) in texts.enumerated() {
            let y = CGFloat(i) * 0.1
            let n = max(text.count, 1)
            let boxes = (0..<text.count).map {
                CGRect(x: CGFloat($0)/CGFloat(n), y: y, width: 1.0/CGFloat(n), height: 0.08)
            }
            lines.append(RecognizedLine(text: text, box: CGRect(x: 0, y: y, width: 1, height: 0.08), charBoxes: boxes))
        }
        return RecognizedTextLayout(lines: lines)
    }
    private let tile = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    func test_singleLine_oneRect() {
        let r = spanRects("x@b.io", in: layout(["mail x@b.io z"]), tile: tile)
        XCTAssertEqual(r.count, 1)
    }
    func test_multiLine_rectPerLine() {
        let r = spanRects("5322\n2596\n2153\n2368",
                          in: layout(["5322", "2596", "2153", "2368"]), tile: tile)
        XCTAssertEqual(r.count, 4)
    }
    func test_sequential_skipsEarlierDuplicate() {
        // frag1 "X" → line 0; frag2 "X" must map to line 2 (searched after line 0),
        // not back to line 0. Distinct y ⇒ the two rects differ.
        let r = spanRects("X\nX", in: layout(["X", "Y", "X"]), tile: tile)
        XCTAssertEqual(r.count, 2)
        XCTAssertNotEqual(r[0].minY, r[1].minY, "second fragment must map to a later line, not the duplicate")
    }
    func test_fragmentAbsent_skipped() {
        let r = spanRects("5322\nZZZZ\n2153", in: layout(["5322", "2153"]), tile: tile)
        XCTAssertEqual(r.count, 2)   // 5322 + 2153 found, ZZZZ skipped
    }
    func test_empty_noRects() {
        XCTAssertTrue(spanRects("   ", in: layout(["abc"]), tile: tile).isEmpty)
    }
}
