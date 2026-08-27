import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class SpanRectsAllOccurrencesTests: XCTestCase {
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

    func test_allOccurrencesAcrossLines() {
        let r = spanRectsAllOccurrences("10,000",
                    in: layout(["Investments 10,000", "Common stock 10,000"]), tile: tile)
        XCTAssertEqual(r.count, 2)
    }
    func test_twoOnSameLine() {
        let r = spanRectsAllOccurrences("10,000", in: layout(["10,000 and 10,000"]), tile: tile)
        XCTAssertEqual(r.count, 2)
    }
    func test_multiLineDelegates() {
        // Contains "\n" → delegate to spanRects (per-line fragments).
        let r = spanRectsAllOccurrences("5322\n2596", in: layout(["5322", "2596"]), tile: tile)
        XCTAssertEqual(r.count, 2)
    }
    func test_fallbackWhenOnlyEmbedded() {
        // "200" only appears inside "200,000" → token rule finds none → fall back
        // to first-occurrence spanRects so the detection is not lost.
        let r = spanRectsAllOccurrences("200", in: layout(["200,000 total"]), tile: tile)
        XCTAssertEqual(r.count, 1)
    }
}
