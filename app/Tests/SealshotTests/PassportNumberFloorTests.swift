import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class PassportNumberFloorTests: XCTestCase {
    // MARK: MRZ line-2 parser
    func test_parsesPassportNumberFromMRZLine2() {
        XCTAssertEqual(
            SensitiveTextRules.passportNumberFromMRZLine("ZE000509<9CAN8501019F2301147<<<<<<<<<<<<<<00"),
            "ZE000509")
    }
    func test_rejectsMRZLine1AndOrdinaryText() {
        XCTAssertNil(SensitiveTextRules.passportNumberFromMRZLine("P<CANMARTIN<<SARAH<<<<<<<<<<<<<<<<<<<<<<<<<<<"))
        XCTAssertNil(SensitiveTextRules.passportNumberFromMRZLine("Total assets and liabilities 472,100"))
        XCTAssertNil(SensitiveTextRules.passportNumberFromMRZLine("ZE000509"))            // too short / no MRZ filler
        XCTAssertNil(SensitiveTextRules.passportNumberFromMRZLine("ABCDEFGH<ABCDEFGHIJKLMNOPQRSTUV<<<<<<<<")) // no digit in field
    }

    // MARK: floor emits a high-risk, always-kept detection mapped to all occurrences
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
    func test_floorEmitsPassportNumberCoveringTopAndMRZ() {
        let dets = SmartRedactionAnalyzer.passportNumberDetections(
            in: layout(["ZE000509", "Surname MARTIN", "ZE000509<9CAN8501019F2301147<<<<<<<<<<<<<<00"]),
            tile: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].snippet, "ZE000509")
        XCTAssertEqual(dets[0].customLabel, "passport number")
        XCTAssertGreaterThanOrEqual(dets[0].rects.count, 2)              // top value + MRZ occurrence
        XCTAssertTrue(EditorState.defaultKept(dets[0]))                  // high-risk via "passport" keyword
    }
}
