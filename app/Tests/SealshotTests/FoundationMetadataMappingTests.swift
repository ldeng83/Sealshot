import XCTest
@testable import Sealshot

/// Pure mapping from the Foundation Model's raw fields to `CaptureMetadata`.
/// No model dependency, so it runs on the build machine.
final class FoundationMetadataMappingTests: XCTestCase {

    func test_category_exactMatch() {
        XCTAssertEqual(screenshotCategory(fromModel: "error"), .error)
        XCTAssertEqual(screenshotCategory(fromModel: "receipt"), .receipt)
    }

    func test_category_caseAndWhitespaceTolerant() {
        XCTAssertEqual(screenshotCategory(fromModel: "  Code "), .code)
        XCTAssertEqual(screenshotCategory(fromModel: "DASHBOARD"), .dashboard)
    }

    func test_category_unknownFallsBackToOther() {
        XCTAssertEqual(screenshotCategory(fromModel: "spreadsheet"), .other)
        XCTAssertEqual(screenshotCategory(fromModel: ""), .other)
    }

    func test_metadata_trimsTitle_normalizesTags_clampsConfidence() {
        let md = captureMetadata(generatedTitle: "  Login failed  ",
                                 categoryRaw: "ERROR",
                                 tags: ["Auth Error", "auth_error", "JS"],
                                 confidence: 1.4,
                                 version: 100)
        XCTAssertEqual(md.generatedTitle, "Login failed")
        XCTAssertEqual(md.category, .error)
        XCTAssertEqual(md.confidence, 1.0, accuracy: 0.001, "confidence clamped to 1.0")
        XCTAssertEqual(md.generatorVersion, 100)
        // kebab-cased, deduped, synonym-mapped (js → javascript) — lands in smartKeywords
        XCTAssertEqual(md.smartKeywords, ["auth-error", "javascript"])
        XCTAssertEqual(md.tags, [])
    }

    func test_metadata_clampsNegativeConfidenceToZero() {
        let md = captureMetadata(generatedTitle: "x", categoryRaw: "other",
                                 tags: [], confidence: -0.5, version: 1)
        XCTAssertEqual(md.confidence, 0.0, accuracy: 0.001)
    }
}
