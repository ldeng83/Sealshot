import XCTest
import AppKit
@testable import Sealshot

final class SummaryKeywordHighlighterTests: XCTestCase {

    private func subs(_ ranges: [NSRange], in text: String) -> [String] {
        let ns = text as NSString
        return ranges.map { ns.substring(with: $0) }
    }

    func test_keywordRanges_findsEntities_excludesNumbers() {
        let text = "John Smith visited London on day 5."
        let s = subs(SummaryKeywordHighlighter.keywordRanges(in: text), in: text)
        XCTAssertTrue(s.contains { ["John", "Smith", "John Smith", "London"].contains($0) },
                      "expected a person/place entity; got \(s)")
        XCTAssertFalse(s.contains("5"), "numbers should not be highlighted; got \(s)")
    }

    func test_keywordRanges_includesMultiWordNounPhrases() {
        // No proper nouns here — the value is the compound nouns.
        let text = "The login error blocked the payment process."
        let s = subs(SummaryKeywordHighlighter.keywordRanges(in: text), in: text)
        XCTAssertTrue(s.contains { $0.lowercased().contains("login error") || $0.lowercased().contains("payment process") },
                      "expected a multi-word noun phrase; got \(s)")
        // Trivial leading word should not be highlighted on its own.
        XCTAssertFalse(s.contains("The"), "should not highlight a bare article/word; got \(s)")
    }

    func test_keywordRanges_matchesCaptureTags() {
        let text = "Invoice from a vendor is overdue."
        let s = subs(SummaryKeywordHighlighter.keywordRanges(in: text, tags: ["invoice"]), in: text)
        XCTAssertTrue(s.contains { $0.lowercased() == "invoice" },
                      "expected the tag 'invoice' highlighted (case-insensitive); got \(s)")
    }

    func test_keywordRanges_capsAtMax() {
        let text = "John Smith met Mary Jones and Peter Parker near London and Paris and Berlin today."
        let ranges = SummaryKeywordHighlighter.keywordRanges(in: text, maxKeywords: 3)
        XCTAssertLessThanOrEqual(ranges.count, 3, "must cap to maxKeywords")
        // Selected ranges must not overlap.
        let sorted = ranges.sorted { $0.location < $1.location }
        for i in 1..<max(sorted.count, 1) where sorted.count > 1 {
            XCTAssertGreaterThanOrEqual(sorted[i].location, NSMaxRange(sorted[i - 1]),
                                        "selected ranges must not overlap")
        }
    }
}
