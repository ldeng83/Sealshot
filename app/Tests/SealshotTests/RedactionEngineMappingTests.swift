import XCTest
import RedactionEngineInterface
@testable import Sealshot

@MainActor
final class RedactionEngineMappingTests: XCTestCase {
    private func layout(_ text: String, y: CGFloat = 0.4) -> RecognizedTextLayout {
        let n = max(text.count, 1)
        let boxes = (0..<text.count).map {
            CGRect(x: CGFloat($0)/CGFloat(n), y: y, width: 1.0/CGFloat(n), height: 0.1)
        }
        return RecognizedTextLayout(lines: [
            RecognizedLine(text: text, box: CGRect(x: 0, y: y, width: 1, height: 0.1), charBoxes: boxes)
        ])
    }
    func test_mapsEngineDetectionToRect_withCategoryAndConfidence() {
        let tile = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let found = [EngineDetection(label: "email address", text: "a@b.io", confidence: 0.93)]
        let dets = SmartRedactionAnalyzer.engineDetections(found, in: layout("mail a@b.io"), tile: tile)
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].category, .email)
        XCTAssertEqual(dets[0].confidence, 0.93, accuracy: 0.001)
        XCTAssertFalse(dets[0].rects.isEmpty)
    }
    func test_unknownLabel_fallsBackToContextualWithCustomLabel() {
        let dets = SmartRedactionAnalyzer.engineDetections(
            [EngineDetection(label: "Loyalty number", text: "778899", confidence: 0.8)],
            in: layout("id 778899"), tile: CGRect(x: 0, y: 0, width: 1000, height: 500))
        XCTAssertEqual(dets.first?.category, .contextual)
        XCTAssertEqual(dets.first?.customLabel, "Loyalty number")
    }
    func test_textNotInAnyLine_skipped() {
        XCTAssertTrue(SmartRedactionAnalyzer.engineDetections(
            [EngineDetection(label: "email address", text: "zzz", confidence: 0.9)],
            in: layout("hello"), tile: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    }
}
