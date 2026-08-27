import XCTest
import CoreGraphics
@testable import Sealshot

final class KeyValueExtractorTests: XCTestCase {

    /// Token centered at (midX, midY); small fixed size.
    private func tok(_ text: String, midX: CGFloat, midY: CGFloat) -> LayoutToken {
        let w: CGFloat = 0.04, h: CGFloat = 0.03
        return LayoutToken(text: text, rect: CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h))
    }

    // MARK: inline-colon

    func test_inlineColon_basicField() {
        // One row; columns: 0.10,0.20,0.30 → 2 cuts → not two-column, only colon runs.
        let tokens = [
            tok("Invoice", midX: 0.10, midY: 0.10),
            tok("No:",     midX: 0.20, midY: 0.10),
            tok("12345",   midX: 0.30, midY: 0.10),
        ]
        let f = KeyValueExtractor.extract(tokens, tolerance: 0.02, columnSeparation: 0.04)
        XCTAssertEqual(f, [StructuredField(label: "Invoice No", value: "12345")])
    }

    func test_inlineColon_splitsOnFirstColonOnly() {
        let tokens = [
            tok("Time:", midX: 0.10, midY: 0.10),
            tok("12:30", midX: 0.20, midY: 0.10),
            tok("PM",    midX: 0.30, midY: 0.10),
        ]
        let f = KeyValueExtractor.extract(tokens, tolerance: 0.02, columnSeparation: 0.04)
        XCTAssertEqual(f, [StructuredField(label: "Time", value: "12:30 PM")])
    }

    func test_inlineColon_rejectsLongProseValue() {
        // value has 13 words (> 12) → not a field.
        let words = (1...13).map { "w\($0)" }
        var tokens = [tok("Note:", midX: 0.10, midY: 0.10)]
        for (i, w) in words.enumerated() {
            tokens.append(tok(w, midX: 0.20 + CGFloat(i) * 0.01, midY: 0.10))
        }
        let f = KeyValueExtractor.extract(tokens, tolerance: 0.02, columnSeparation: 0.04)
        XCTAssertEqual(f, [])
    }

    func test_inlineColon_rejectsHttpsUrl() {
        let tokens = [tok("https://example.com", midX: 0.10, midY: 0.10)]
        let f = KeyValueExtractor.extract(tokens, tolerance: 0.02, columnSeparation: 0.04)
        XCTAssertEqual(f, [])
    }

    func test_inlineColon_rejectsNumericKey() {
        // "12:30" alone → key "12" has no letter → rejected.
        let tokens = [tok("12:30", midX: 0.10, midY: 0.10)]
        let f = KeyValueExtractor.extract(tokens, tolerance: 0.02, columnSeparation: 0.04)
        XCTAssertEqual(f, [])
    }

    // MARK: two-column

    func test_twoColumn_labelValueRows() {
        // Intra-cell words within 0.04; big gap between the label and value columns.
        let tokens = [
            tok("Patient", midX: 0.12, midY: 0.10), tok("Name", midX: 0.15, midY: 0.10),
            tok("John",    midX: 0.68, midY: 0.10), tok("Smith", midX: 0.71, midY: 0.10),
            tok("Status",  midX: 0.13, midY: 0.25),
            tok("Active",  midX: 0.69, midY: 0.25),
        ]
        let f = KeyValueExtractor.extract(tokens, tolerance: 0.02, columnSeparation: 0.04)
        XCTAssertEqual(f, [
            StructuredField(label: "Patient Name", value: "John Smith"),
            StructuredField(label: "Status", value: "Active"),
        ])
    }

    func test_multiColumn_disablesTwoColumn() {
        // Three columns (2 cuts) → two-column pattern off; no colon → no fields.
        let tokens = [
            tok("A", midX: 0.10, midY: 0.10), tok("B", midX: 0.45, midY: 0.10), tok("C", midX: 0.80, midY: 0.10),
            tok("D", midX: 0.10, midY: 0.25), tok("E", midX: 0.45, midY: 0.25), tok("F", midX: 0.80, midY: 0.25),
        ]
        let f = KeyValueExtractor.extract(tokens, tolerance: 0.02, columnSeparation: 0.04)
        XCTAssertEqual(f, [])
    }

    // MARK: dedup

    func test_dedup_identicalPairsCollapse() {
        let tokens = [
            tok("Status:", midX: 0.10, midY: 0.10), tok("Active", midX: 0.20, midY: 0.10),
            tok("Status:", midX: 0.10, midY: 0.30), tok("Active", midX: 0.20, midY: 0.30),
        ]
        let f = KeyValueExtractor.extract(tokens, tolerance: 0.02, columnSeparation: 0.04)
        XCTAssertEqual(f, [StructuredField(label: "Status", value: "Active")])
    }
}
