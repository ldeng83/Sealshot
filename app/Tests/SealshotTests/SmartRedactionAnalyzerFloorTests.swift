import XCTest
@testable import Sealshot

@MainActor
final class SmartRedactionAnalyzerFloorTests: XCTestCase {
    private func layout(_ text: String) -> RecognizedTextLayout {
        let n = max(text.count, 1)
        let boxes = (0..<text.count).map {
            CGRect(x: CGFloat($0)/CGFloat(n), y: 0.4, width: 1.0/CGFloat(n), height: 0.1)
        }
        return RecognizedTextLayout(lines: [
            RecognizedLine(text: text, box: CGRect(x: 0, y: 0.4, width: 1, height: 0.1), charBoxes: boxes)])
    }
    private let tile = CGRect(x: 0, y: 0, width: 1000, height: 500)

    func test_engineOff_includesNER() {
        // NLTagger needs surrounding sentence context to classify names reliably.
        let cats = SmartRedactionAnalyzer.detections(
            in: layout("Meeting with Jasen Gaylord today"), tile: tile, includeContextual: true).map(\.category)
        XCTAssertTrue(cats.contains(.personName))
    }
    func test_enginePath_dropsNER_butKeepsLabeledField() {
        // includeContextual:false simulates the GLiNER2-active path.
        let cats = SmartRedactionAnalyzer.detections(
            in: layout("DOB: 01/02/1985 meeting with Jasen Gaylord"),
            tile: tile, includeContextual: false).map(\.category)
        XCTAssertTrue(cats.contains(.labeledField), "anchored label→value must survive on the engine path")
        XCTAssertFalse(cats.contains(.personName), "NLTagger NER must be excluded on the engine path")
    }
}
