import XCTest
@testable import Sealshot

final class SearchQueryExpanderTests: XCTestCase {

    func test_ftsOrQuery_joinsPrefixTermsWithOR() {
        XCTAssertEqual(SearchQueryExpander.ftsOrQuery(terms: ["auth", "401"]),
                       "\"auth\"* OR \"401\"*")
    }

    func test_ftsOrQuery_dropsEmpty_andCaseInsensitiveDuplicates() {
        XCTAssertEqual(SearchQueryExpander.ftsOrQuery(terms: ["Auth", " auth ", "", "401"]),
                       "\"Auth\"* OR \"401\"*")
    }

    func test_ftsOrQuery_escapesQuotes() {
        XCTAssertEqual(SearchQueryExpander.ftsOrQuery(terms: ["a\"b"]), "\"a\"\"b\"*")
    }

    func test_ftsOrQuery_nilWhenNoUsableTerms() {
        XCTAssertNil(SearchQueryExpander.ftsOrQuery(terms: ["", "   "]))
        XCTAssertNil(SearchQueryExpander.ftsOrQuery(terms: []))
    }

    func test_prompt_includesQuery_andInstructionsNonEmpty() {
        XCTAssertTrue(SearchQueryPromptBuilder.prompt(query: "auth errors").contains("auth errors"))
        XCTAssertFalse(SearchQueryPromptBuilder.instructions.isEmpty)
    }
}
