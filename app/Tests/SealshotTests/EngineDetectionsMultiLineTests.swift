import XCTest
import RedactionEngineInterface
@testable import Sealshot

@MainActor
final class EngineDetectionsMultiLineTests: XCTestCase {
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
    func test_multiLineEngineSpan_oneDetectionMultipleRects() {
        let found = [EngineDetection(label: "credit card number",
                                     text: "5322\n2596\n2153\n2368", confidence: 0.95)]
        let dets = SmartRedactionAnalyzer.engineDetections(
            found, in: layout(["5322", "2596", "2153", "2368"]),
            tile: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].category, .creditCard)
        XCTAssertEqual(dets[0].rects.count, 4)
    }

    func test_engineDetections_repeatedValue_allRects() {
        let found = [EngineDetection(label: "money amount", text: "10,000", confidence: 0.6)]
        let dets = SmartRedactionAnalyzer.engineDetections(
            found, in: layout(["Investments 10,000", "Common stock 10,000"]),
            tile: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].rects.count, 2)
    }
}
