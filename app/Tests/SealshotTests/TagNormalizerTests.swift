import XCTest
@testable import Sealshot

final class TagNormalizerTests: XCTestCase {

    func testKebabAndLowercase() {
        XCTAssertEqual(TagNormalizer.normalize(["Pull Request", "Card_Declined"]),
                       ["pull-request", "card-declined"])
    }

    func testStripsUnsafeCharsAndEmpties() {
        XCTAssertEqual(TagNormalizer.normalize(["c++!!", "  ", "a/b"]),
                       ["c", "a-b"])
    }

    func testAppliesSynonyms() {
        XCTAssertEqual(TagNormalizer.normalize(["js", "authn", "mac os"]),
                       ["javascript", "authentication", "macos"])
    }

    func testDedupesPreservingFirstOrder() {
        XCTAssertEqual(TagNormalizer.normalize(["error", "Error", "code", "error"]),
                       ["error", "code"])
    }

    func testCapsAtEight() {
        let many = (1...12).map { "tag\($0)" }
        XCTAssertEqual(TagNormalizer.normalize(many).count, 8)
    }

    func testSingularizesPluralNouns() {
        XCTAssertEqual(TagNormalizer.normalize(["bugs", "reports", "errors"]),
                       ["bug", "report", "error"])
    }

    func testSingularizesEachTokenOfKebabTag() {
        XCTAssertEqual(TagNormalizer.normalize(["bug-reports"]), ["bug"])
    }

    func testDoesNotLemmatizeVerbsOrAdjectives() {
        // "declined" must NOT become "decline" — only plural-noun shapes collapse.
        XCTAssertEqual(TagNormalizer.normalize(["card-declined"]), ["card-declined"])
    }

    func testProtectsCategoryNamesFromSingularization() {
        // "settings" is a category; it must survive intact.
        XCTAssertEqual(TagNormalizer.normalize(["settings"]), ["settings"])
    }

    func testMapsBugReportSynonymsToBug() {
        XCTAssertEqual(TagNormalizer.normalize(["bug-report", "defect"]), ["bug"])
    }

    func testDoesNotSingularizeTokensWithDigits() {
        let many = (1...12).map { "tag\($0)" }
        XCTAssertEqual(TagNormalizer.normalize(many).count, 8)
    }

    func testDoesNotCorruptLatinSingularNouns() {
        // NLTagger leaves these unchanged; no naive suffix-stripping must mangle them.
        XCTAssertEqual(TagNormalizer.normalize(["focus", "status", "bonus"]),
                       ["focus", "status", "bonus"])
    }

    func testFormatKeepsPluralsAndSkipsSynonyms() {
        // format() must NOT singularize or apply synonyms — only formatting.
        XCTAssertEqual(TagNormalizer.format(["Bugs"]), ["bugs"])
        XCTAssertEqual(TagNormalizer.format(["Bug Report"]), ["bug-report"])
        XCTAssertEqual(TagNormalizer.format(["js"]), ["js"])
    }

    func testFormatStillKebabsStripsDedupsAndCaps() {
        XCTAssertEqual(TagNormalizer.format(["Card_Declined", "c++!!", "  ", "Card declined"]),
                       ["card-declined", "c"])
        XCTAssertEqual(TagNormalizer.format((1...12).map { "tag\($0)" }).count, 8)
    }

    func testNormalizeUnchangedStillSingularizesAndSynonyms() {
        XCTAssertEqual(TagNormalizer.normalize(["bugs", "bug-report"]), ["bug"])
    }
}
