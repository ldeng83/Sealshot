import XCTest
@testable import Sealshot

final class RedactionCoverageBenchmarkTests: XCTestCase {
    /// Run the always-on (model-free) layers over a case's text.
    private func matches(_ text: String) -> [SensitiveMatch] {
        // Mirror the analyzer's per-line application (anchored layer always on).
        text.split(separator: "\n", omittingEmptySubsequences: false).flatMap { line -> [SensitiveMatch] in
            let s = String(line)
            return SensitiveTextRules.combinedMatches(in: s, additional: ContextualDetectors.anchoredMatches(in: s))
        }
    }
    func test_coverageFixtures() {
        for c in RedactionCoverageFixtures.all {
            let found = matches(c.ocrText)
            for (cat, text) in c.expect {
                let hit = found.contains { $0.category == cat && $0.text.contains(text) }
                XCTAssertTrue(hit, "[\(c.docType)/\(c.id)] expected \(cat) span \"\(text)\" not detected; found: \(found.map { "\($0.category):\($0.text)" })")
            }
            for r in c.reject {
                let bad = found.contains { $0.text.contains(r) }
                XCTAssertFalse(bad, "[\(c.docType)/\(c.id)] reject span \"\(r)\" was flagged")
            }
        }
    }
}
