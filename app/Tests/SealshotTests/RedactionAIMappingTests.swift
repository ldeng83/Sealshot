import XCTest
@testable import Sealshot

/// Pure helpers for FM-assisted Smart Redaction: prompt assembly, locating a
/// model-returned verbatim span inside an OCR line, and false-positive damping.
/// No model dependency — runs on the build machine.
final class RedactionAIMappingTests: XCTestCase {

    // MARK: Prompt

    func test_prompt_includesOCRandDetectedList() {
        let p = RedactionPromptBuilder.prompt(ocrText: "code 778899",
                                              alreadyDetected: ["192.168.0.1"],
                                              maxOCRChars: 4_000)
        XCTAssertTrue(p.contains("778899"))
        XCTAssertTrue(p.contains("192.168.0.1"))
    }

    func test_prompt_omitsDetectedSectionWhenEmpty() {
        let p = RedactionPromptBuilder.prompt(ocrText: "hello", alreadyDetected: [], maxOCRChars: 4_000)
        XCTAssertTrue(p.contains("hello"))
        XCTAssertFalse(p.lowercased().contains("false positive"))
    }

    func test_prompt_truncatesOCR() {
        let big = String(repeating: "q", count: 9_000)
        let p = RedactionPromptBuilder.prompt(ocrText: big, alreadyDetected: [], maxOCRChars: 500)
        XCTAssertLessThan(p.count, 1_000)
    }

    // MARK: Locate span in lines

    func test_locateSpan_foundInLine_returnsCharRange() {
        let located = locateSpan("123456", inLineTexts: ["Your code", "is 123456 now"])
        XCTAssertEqual(located?.lineIndex, 1)
        XCTAssertEqual(located?.range, 3..<9)   // "is " then "123456"
    }

    func test_locateSpan_trimsWhitespace() {
        let located = locateSpan("  alice@x.com ", inLineTexts: ["email: alice@x.com"])
        XCTAssertEqual(located?.lineIndex, 0)
        XCTAssertEqual(located?.range, 7..<18)
    }

    func test_locateSpan_notFound_returnsNil() {
        XCTAssertNil(locateSpan("nope", inLineTexts: ["alpha", "beta"]))
        XCTAssertNil(locateSpan("   ", inLineTexts: ["alpha"]))
    }

    // MARK: False-positive damping (never removes)

    func test_dampedConfidence_lowersWhenFlagged_keepsOtherwise() {
        XCTAssertEqual(dampedConfidence(base: 0.9, isFlaggedFalsePositive: true), 0.36, accuracy: 0.001)
        XCTAssertEqual(dampedConfidence(base: 0.9, isFlaggedFalsePositive: false), 0.9, accuracy: 0.001)
    }

    func test_isFalsePositive_exactMembership() {
        let flagged: Set<String> = ["v1.2.3", "order-99812"]
        XCTAssertTrue(isFalsePositive("v1.2.3", flagged: flagged))
        XCTAssertFalse(isFalsePositive("123-45-6789", flagged: flagged))
    }
}
