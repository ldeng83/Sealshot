import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class MoneyFloorDetectionsTests: XCTestCase {
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

    func test_emitsMoneyAmountForFinancialFigures() {
        let dets = SmartRedactionAnalyzer.moneyFloorDetections(
            in: layout(["Less amortization (200)", "Deferred revenue 2,000", "page 42"]),
            tile: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(dets.count, 2)   // (200) and 2,000; not "42"
        XCTAssertTrue(dets.allSatisfy { $0.category == .contextual && $0.customLabel == "money amount" })
        XCTAssertTrue(dets.allSatisfy { !$0.rects.isEmpty })
    }
}
