import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class CardExpiryDetectionsTests: XCTestCase {
    private func layout(_ rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)]) -> RecognizedTextLayout {
        let lines = rows.map { (t, x, y, w, h) -> RecognizedLine in
            let n = max(t.count, 1)
            let boxes = (0..<t.count).map { CGRect(x: x + CGFloat($0)/CGFloat(n)*w, y: y, width: w/CGFloat(n), height: h) }
            return RecognizedLine(text: t, box: CGRect(x: x, y: y, width: w, height: h), charBoxes: boxes)
        }
        return RecognizedTextLayout(lines: lines)
    }
    private let tile = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    func test_catchesSplitExpiryAcrossTokens() {
        // "01/" and "25" as separate tokens on the same row (the purple-card case).
        let l = layout([("01/", 0.49, 0.80, 0.05, 0.02), ("25", 0.54, 0.80, 0.03, 0.02)])
        let dets = SmartRedactionAnalyzer.cardExpiryDetections(in: l, tile: tile)
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].customLabel, "card expiry")
        XCTAssertTrue(EditorState.defaultKept(dets[0]))
    }

    func test_catchesSingleTokenExpiry() {
        let l = layout([("01/ 25", 0.49, 0.80, 0.08, 0.02)])
        XCTAssertEqual(SmartRedactionAnalyzer.cardExpiryDetections(in: l, tile: tile).count, 1)
    }

    func test_ignoresNonExpiryRow() {
        let l = layout([("LOREM IPSUM", 0.16, 0.62, 0.20, 0.02)])
        XCTAssertTrue(SmartRedactionAnalyzer.cardExpiryDetections(in: l, tile: tile).isEmpty)
    }
}
