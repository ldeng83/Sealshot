import XCTest
@testable import Sealshot

@MainActor
final class FloorEmailPhoneTests: XCTestCase {
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

    func test_floor_detectsCleanEmail() {
        let d = SmartRedactionAnalyzer.detections(in: layout(["dsmith@example.com"]),
                                                  tile: tile, includeContextual: false)
        XCTAssertTrue(d.contains { $0.category == .email }, "floor must catch a clean email")
    }
    func test_floor_detectsCleanPhone() {
        let d = SmartRedactionAnalyzer.detections(in: layout(["800-555-0100"]),
                                                  tile: tile, includeContextual: false)
        XCTAssertTrue(d.contains { $0.category == .phone }, "floor must catch a clean phone")
    }
    func test_floor_detectsEmailInLabeledCell() {
        // The table-cell case: label + value on one OCR line.
        let d = SmartRedactionAnalyzer.detections(in: layout(["Email dsmith@example.com"]),
                                                  tile: tile, includeContextual: false)
        XCTAssertTrue(d.contains { $0.category == .email }, "floor must catch email in a labeled cell")
    }
}
