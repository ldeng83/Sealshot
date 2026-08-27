import XCTest
@testable import Sealshot

final class RuleBasedTagsTests: XCTestCase {

    private let gen = RuleBasedMetadataGenerator()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    /// Returns auto-generated keywords (smartKeywords), not user tags.
    private func keywords(ocr: String = "", app: String? = nil, title: String? = nil) -> [String] {
        gen.generate(MetadataSignals(ocrText: ocr, sourceApp: app, windowTitle: title,
                                     captureDate: date, imageWidth: 1, imageHeight: 1)).smartKeywords
    }

    func test_ruleBasedGenerator_populatesSmartKeywords_notTags() {
        let m = gen.generate(MetadataSignals(ocrText: "stripe checkout invoice", sourceApp: "Safari",
                                              windowTitle: nil, captureDate: date,
                                              imageWidth: 1, imageHeight: 1))
        XCTAssertTrue(m.smartKeywords.contains("stripe"))
        XCTAssertTrue(m.tags.isEmpty)
    }

    func testIncludesCategoryAndAppSlug() {
        let t = keywords(ocr: "request failed", app: "Google Chrome")
        XCTAssertFalse(t.contains("error"))        // category no longer tagged
        XCTAssertTrue(t.contains("google-chrome")) // app slug
    }

    func testIncludesContentKeywords() {
        let t = keywords(ocr: "Stripe checkout: card was declined")
        XCTAssertTrue(t.contains("stripe"))
    }

    func testCappedAtEight() {
        let t = keywords(ocr: "stripe github aws figma error payment checkout invoice slack",
                         app: "Safari")
        XCTAssertLessThanOrEqual(t.count, 8)
    }

    /// An OCR that classifies to a non-.other category but contains no keyword
    /// or app name must produce an empty smartKeywords list — the category word
    /// is no longer surfaced as a keyword.
    func testCategoryOCRProducesNoTagsWithoutKeywordOrApp() {
        // "request failed" classifies as .error; no keyword tags, no app
        let t = keywords(ocr: "request failed")
        XCTAssertFalse(t.contains("error"), "category word must not appear in smartKeywords")
        XCTAssertTrue(t.isEmpty, "no keyword or app → empty smartKeywords")
    }
}
