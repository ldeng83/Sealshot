import XCTest
@testable import Sealshot

final class ContextualDetectorsSplitTests: XCTestCase {
    func test_anchored_hasLabeledFieldAndAddress_noNER() {
        let cats = ContextualDetectors.anchoredMatches(in: "DOB: 01/02/1985").map(\.category)
        XCTAssertTrue(cats.contains(.labeledField))
        XCTAssertFalse(cats.contains(.personName))
    }
    func test_namedEntity_isNEROnly() {
        // A name with no label → only the NER layer should surface it.
        let anchored = ContextualDetectors.anchoredMatches(in: "Meeting with Jasen Gaylord today").map(\.category)
        XCTAssertFalse(anchored.contains(.personName))
        let ner = ContextualDetectors.namedEntityMatches(in: "Meeting with Jasen Gaylord today").map(\.category)
        XCTAssertTrue(ner.contains(.personName))
    }
    func test_matches_equalsUnion() {
        let line = "DOB: 01/02/1985 — patient Jasen Gaylord"
        let union = (ContextualDetectors.anchoredMatches(in: line) + ContextualDetectors.namedEntityMatches(in: line))
        XCTAssertEqual(Set(ContextualDetectors.matches(in: line).map(\.text)),
                       Set(union.map(\.text)))
    }
}
