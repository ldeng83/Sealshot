import XCTest
@testable import Sealshot

/// FM-augmentation helpers on SmartRedactionAnalyzer: mapping model-found spans
/// to `.contextual` detections, and damping (never removing) flagged false
/// positives. Synthetic layouts — no Vision, no model.
@MainActor
final class SmartRedactionAITests: XCTestCase {

    private func layout(_ text: String, y: CGFloat = 0.4) -> RecognizedTextLayout {
        let count = max(text.count, 1)
        let charBoxes = (0..<text.count).map {
            CGRect(x: CGFloat($0) / CGFloat(count), y: y, width: 1.0 / CGFloat(count), height: 0.1)
        }
        return RecognizedTextLayout(lines: [
            RecognizedLine(text: text, box: CGRect(x: 0, y: y, width: 1, height: 0.1), charBoxes: charBoxes)
        ])
    }

    private func finding(_ text: String, type: String = "Confirmation code",
                         reason: String = "A one-time code.") -> RedactionFinding {
        RedactionFinding(text: text, type: type, reason: reason)
    }

    func test_contextualDetections_mapsFindingToRect_withTypeAndReason() {
        let tile = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let dets = SmartRedactionAnalyzer.contextualDetections(
            findings: [finding("778899")], in: layout("code 778899"), tile: tile)
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].category, .contextual)
        XCTAssertEqual(dets[0].snippet, SensitiveTextRules.displaySnippet(for: "778899"))
        XCTAssertEqual(dets[0].customLabel, "Confirmation code")
        XCTAssertEqual(dets[0].reason, "A one-time code.")
        XCTAssertFalse(dets[0].rects.isEmpty)
    }

    func test_contextualDetections_skipsFindingNotFoundInAnyLine() {
        let dets = SmartRedactionAnalyzer.contextualDetections(
            findings: [finding("zzzz")], in: layout("hello"),
            tile: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(dets.isEmpty)
    }

    func test_newFindings_dropsItemsAlreadyDetectedByRules() {
        let findings = [finding("jasen@you.mail", type: "Email"),
                        finding("778899")]
        let kept = SmartRedactionAnalyzer.newFindings(findings, excluding: ["JASEN@you.mail "])
        XCTAssertEqual(kept.map(\.text), ["778899"], "the already-detected email is dropped")
    }

    func test_falsePositiveFlag_lowersConfidence_butKeepsDetection() {
        let tile = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let l = layout("mail a@b.io")
        let normal = SmartRedactionAnalyzer.detections(in: l, tile: tile)
        let flagged = SmartRedactionAnalyzer.detections(in: l, tile: tile,
                                                        falsePositiveTexts: ["a@b.io"])
        XCTAssertEqual(normal.count, 1)
        XCTAssertEqual(flagged.count, 1, "flagging a false positive must never remove the detection")
        XCTAssertEqual(flagged[0].confidence,
                       normal[0].confidence * falsePositiveConfidenceFactor, accuracy: 0.001)
    }
}
