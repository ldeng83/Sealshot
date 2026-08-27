import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class CardholderNameDetectionsTests: XCTestCase {
    private func layout(_ rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)]) -> RecognizedTextLayout {
        let lines = rows.map { (t, x, y, w, h) -> RecognizedLine in
            let n = max(t.count, 1)
            let boxes = (0..<t.count).map { CGRect(x: x + CGFloat($0)/CGFloat(n)*w, y: y, width: w/CGFloat(n), height: h) }
            return RecognizedLine(text: t, box: CGRect(x: x, y: y, width: w, height: h), charBoxes: boxes)
        }
        return RecognizedTextLayout(lines: lines)
    }
    private let tile = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    func test_namePredicate() {
        XCTAssertTrue(SmartRedactionAnalyzer.isCardholderName("LOREM IPSUM"))
        XCTAssertTrue(SmartRedactionAnalyzer.isCardholderName("JANE Q SMITH"))
        XCTAssertFalse(SmartRedactionAnalyzer.isCardholderName("BANK NAME"))     // card label
        XCTAssertFalse(SmartRedactionAnalyzer.isCardholderName("CREDIT CARD"))   // card label
        XCTAssertFalse(SmartRedactionAnalyzer.isCardholderName("01 / 25"))       // has digits
        XCTAssertFalse(SmartRedactionAnalyzer.isCardholderName("X"))             // too short
    }

    func test_detectsNameBelowCardNumber() {
        let l = layout([
            ("5322", 0.16, 0.56, 0.06, 0.02), ("2596", 0.23, 0.56, 0.06, 0.02),
            ("2153", 0.31, 0.56, 0.06, 0.02), ("2368", 0.38, 0.56, 0.06, 0.02),
            ("LOREM IPSUM", 0.16, 0.60, 0.18, 0.02),     // directly below the number
        ])
        let dets = SmartRedactionAnalyzer.cardholderNameDetections(in: l, tile: tile)
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].snippet, "LOREM IPSUM")
        XCTAssertEqual(dets[0].customLabel, "cardholder name")
        XCTAssertTrue(EditorState.defaultKept(dets[0]))
    }

    func test_noNameWithoutCardNumber() {
        let l = layout([("LOREM IPSUM", 0.16, 0.60, 0.18, 0.02)])  // no card number above
        XCTAssertTrue(SmartRedactionAnalyzer.cardholderNameDetections(in: l, tile: tile).isEmpty)
    }

    func test_skipsCardLabelBelowNumber() {
        let l = layout([
            ("5322", 0.16, 0.56, 0.06, 0.02), ("2596", 0.23, 0.56, 0.06, 0.02),
            ("2153", 0.31, 0.56, 0.06, 0.02), ("2368", 0.38, 0.56, 0.06, 0.02),
            ("BANK NAME", 0.16, 0.60, 0.18, 0.02),       // a label, not a name
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.cardholderNameDetections(in: l, tile: tile).isEmpty)
    }
}
