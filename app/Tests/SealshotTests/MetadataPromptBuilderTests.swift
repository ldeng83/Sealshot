import XCTest
import CoreGraphics
@testable import Sealshot

/// The prompt/instructions fed to the on-device Foundation Model for metadata
/// generation are built by pure, deterministic helpers (no model needed), so
/// they're unit-testable on any OS — including this build machine, which can't
/// run the model.
final class MetadataPromptBuilderTests: XCTestCase {

    // MARK: OCR excerpt (context-budget truncation)

    func test_ocrExcerpt_shortText_returnedUnchanged() {
        let text = "Payment failed: card declined"
        XCTAssertEqual(MetadataPromptBuilder.ocrExcerpt(text, maxChars: 200), text)
    }

    func test_ocrExcerpt_longText_truncatedToBudget() {
        let text = String(repeating: "a", count: 5_000)
        let excerpt = MetadataPromptBuilder.ocrExcerpt(text, maxChars: 1_000)
        XCTAssertLessThanOrEqual(excerpt.count, 1_000)
    }

    func test_ocrExcerpt_prefersLineBoundary_whenOneExistsInBudget() {
        // Three lines; budget cuts inside line 3 → should trim back to the end
        // of line 2 rather than slice mid-line.
        let text = "line one\nline two\nline three is rather long and overflows"
        let excerpt = MetadataPromptBuilder.ocrExcerpt(text, maxChars: 20)
        XCTAssertEqual(excerpt, "line one\nline two")
    }

    func test_ocrExcerpt_noBoundary_hardTruncatesToBudget() {
        let text = String(repeating: "x", count: 100)   // no newline at all
        let excerpt = MetadataPromptBuilder.ocrExcerpt(text, maxChars: 10)
        XCTAssertEqual(excerpt.count, 10)
    }

    // MARK: User prompt assembly

    private func signals(ocr: String, app: String?, window: String?) -> MetadataSignals {
        MetadataSignals(ocrText: ocr, sourceApp: app, windowTitle: window,
                        captureDate: Date(timeIntervalSince1970: 0),
                        imageWidth: 100, imageHeight: 80)
    }

    func test_userPrompt_includesAppWindowAndOCR() {
        let p = MetadataPromptBuilder.userPrompt(
            from: signals(ocr: "403 Forbidden", app: "Safari", window: "GitHub — Pull Request"),
            maxOCRChars: 4_000)
        XCTAssertTrue(p.contains("Safari"), "source app should be in the prompt")
        XCTAssertTrue(p.contains("GitHub — Pull Request"), "window title should be in the prompt")
        XCTAssertTrue(p.contains("403 Forbidden"), "OCR text should be in the prompt")
    }

    func test_userPrompt_omitsMissingAppAndWindowGracefully() {
        let p = MetadataPromptBuilder.userPrompt(
            from: signals(ocr: "hello world", app: nil, window: nil),
            maxOCRChars: 4_000)
        XCTAssertTrue(p.contains("hello world"))
        XCTAssertFalse(p.lowercased().contains("none"), "missing fields must not leak placeholder noise")
    }

    func test_userPrompt_truncatesOCRToBudget() {
        let big = String(repeating: "z", count: 9_000)
        let p = MetadataPromptBuilder.userPrompt(from: signals(ocr: big, app: nil, window: nil),
                                                 maxOCRChars: 500)
        XCTAssertLessThan(p.count, 1_000, "OCR must be excerpted before going into the prompt")
    }

    // MARK: Instructions

    func test_instructions_nonEmpty() {
        XCTAssertFalse(MetadataPromptBuilder.instructions.isEmpty)
    }
}
