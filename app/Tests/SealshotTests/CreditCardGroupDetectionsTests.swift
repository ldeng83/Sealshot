import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class CreditCardGroupDetectionsTests: XCTestCase {
    /// Build a layout from (text, x, y, w, h) normalized line boxes.
    private func layout(_ rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)]) -> RecognizedTextLayout {
        let lines = rows.map { (t, x, y, w, h) -> RecognizedLine in
            let n = max(t.count, 1)
            let boxes = (0..<t.count).map {
                CGRect(x: x + CGFloat($0)/CGFloat(n)*w, y: y, width: w/CGFloat(n), height: h)
            }
            return RecognizedLine(text: t, box: CGRect(x: x, y: y, width: w, height: h), charBoxes: boxes)
        }
        return RecognizedTextLayout(lines: lines)
    }
    private let tile = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    func test_fourSeparateGroupsSameRow_detectedWithRectPerGroup() {
        // Purple-card case: four individual 4-digit tokens, same y, increasing x.
        let l = layout([
            ("5322", 0.16, 0.56, 0.06, 0.02),
            ("2596", 0.23, 0.56, 0.06, 0.02),
            ("2153", 0.31, 0.56, 0.06, 0.02),
            ("2368", 0.38, 0.56, 0.06, 0.02),
        ])
        let dets = SmartRedactionAnalyzer.creditCardGroupDetections(in: l, tile: tile)
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].category, .creditCard)
        XCTAssertEqual(dets[0].rects.count, 4)              // every group covered, incl. the leading 5322
        XCTAssertTrue(EditorState.defaultKept(dets[0]))     // creditCard is high-risk
    }

    func test_twoGroupsPerLineSameRow_detected() {
        // Red-card case: two lines of two groups, same row.
        let l = layout([
            ("5322 2596", 0.17, 0.25, 0.13, 0.02),
            ("2153 2368", 0.32, 0.25, 0.13, 0.02),
        ])
        let dets = SmartRedactionAnalyzer.creditCardGroupDetections(in: l, tile: tile)
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].rects.count, 4)
    }

    func test_rejectsNonCardBin() {
        // Four adjacent 4-digit groups but starting 1 (not a card BIN) → skipped.
        let l = layout([
            ("1234", 0.16, 0.56, 0.06, 0.02),
            ("5678", 0.23, 0.56, 0.06, 0.02),
            ("9012", 0.31, 0.56, 0.06, 0.02),
            ("3456", 0.38, 0.56, 0.06, 0.02),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.creditCardGroupDetections(in: l, tile: tile).isEmpty)
    }

    func test_rejectsFewerThanFourGroups() {
        let l = layout([
            ("5322", 0.16, 0.56, 0.06, 0.02),
            ("2596", 0.23, 0.56, 0.06, 0.02),
            ("2153", 0.31, 0.56, 0.06, 0.02),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.creditCardGroupDetections(in: l, tile: tile).isEmpty)
    }

    func test_doesNotStitchAcrossDifferentRows() {
        // Two groups on top row, two far below — not one card.
        let l = layout([
            ("5322", 0.16, 0.10, 0.06, 0.02),
            ("2596", 0.23, 0.10, 0.06, 0.02),
            ("2153", 0.16, 0.80, 0.06, 0.02),
            ("2368", 0.23, 0.80, 0.06, 0.02),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.creditCardGroupDetections(in: l, tile: tile).isEmpty)
    }
}
