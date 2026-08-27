import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class LabeledValueDetectionsTests: XCTestCase {
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

    func test_capturesValueOnLineBelowLabel() {
        // Bilingual passport-style label, value stacked directly below, left-aligned.
        let l = layout([
            ("Nationality/Nationalité", 0.1, 0.10, 0.30, 0.03),
            ("CANADIAN/CANADIENNE",     0.1, 0.14, 0.30, 0.03),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].snippet, "CANADIAN/CANADIENNE")
        XCTAssertEqual(dets[0].customLabel, "nationality")
        XCTAssertTrue(EditorState.defaultKept(dets[0]))     // 0.9 ≥ threshold
    }

    func test_passportLabelValueIsHighRiskKept() {
        let l = layout([
            ("Passport No./N° de passeport", 0.5, 0.05, 0.40, 0.03),
            ("ZE000509",                     0.5, 0.09, 0.20, 0.03),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(dets.first?.snippet, "ZE000509")
        XCTAssertTrue(EditorState.isHighRiskLabel(dets.first?.customLabel))   // "passport no" → passport
    }

    func test_rejectsProseLineStartingWithLabelWord() {
        // "Account" leads the line but it's prose (label is a small fraction) → no trigger.
        let l = layout([
            ("Account managers met to discuss the quarter", 0.1, 0.10, 0.6, 0.03),
            ("Revenue grew steadily over the period",        0.1, 0.14, 0.6, 0.03),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile).isEmpty)
    }

    func test_rejectsWhenBelowLineIsAnotherLabel() {
        let l = layout([
            ("Date of birth/Date de naissance", 0.1, 0.10, 0.35, 0.03),
            ("Place of birth/Lieu de naissance", 0.1, 0.14, 0.35, 0.03),  // a label, not a value
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile).isEmpty)
    }

    func test_rejectsWhenBelowLineDoesNotOverlapHorizontally() {
        let l = layout([
            ("Nationality", 0.1, 0.10, 0.15, 0.03),
            ("FARAWAY",     0.8, 0.14, 0.15, 0.03),   // far right column — different field
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile).isEmpty)
    }
}
