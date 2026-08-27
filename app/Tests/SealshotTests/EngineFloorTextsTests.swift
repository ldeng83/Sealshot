import XCTest
@testable import Sealshot

@MainActor
final class EngineFloorTextsTests: XCTestCase {
    private func layout(_ text: String) -> RecognizedTextLayout {
        let n = max(text.count, 1)
        let boxes = (0..<text.count).map {
            CGRect(x: CGFloat($0)/CGFloat(n), y: 0.4, width: 1.0/CGFloat(n), height: 0.1)
        }
        return RecognizedTextLayout(lines: [
            RecognizedLine(text: text, box: CGRect(x: 0, y: 0.4, width: 1, height: 0.1), charBoxes: boxes)])
    }
    func test_includesAnchoredAndRegexValues_fullText() {
        let texts = SmartRedactionAnalyzer.engineFloorTexts(in: layout("DOB: 1985-01-01"))
        // The labeled value (full, not a truncated snippet) is present.
        XCTAssertTrue(texts.contains { $0.contains("1985-01-01") })
    }
    func test_excludesNERNames() {
        // Anchored floor has no NLTagger NER, so a bare name isn't a "floor" text.
        let texts = SmartRedactionAnalyzer.engineFloorTexts(in: layout("Meeting with Jasen Gaylord"))
        XCTAssertFalse(texts.contains { $0.contains("Jasen Gaylord") })
    }
}
