import XCTest
@testable import Sealshot

final class AITextActionPromptBuilderTests: XCTestCase {

    func test_instructions_nonEmpty_andDistinct() {
        XCTAssertFalse(AITextActionPromptBuilder.summaryInstructions.isEmpty)
        XCTAssertFalse(AITextActionPromptBuilder.extractInstructions.isEmpty)
        XCTAssertNotEqual(AITextActionPromptBuilder.summaryInstructions,
                          AITextActionPromptBuilder.extractInstructions)
    }

    /// A scene summary puts one window per bullet, so the per-window prompt
    /// must ask for ONE sentence and forbid lists — otherwise the bullet
    /// contains a paragraph or a nested bullet list. Distinct from both
    /// existing summary prompts, which allow multiple sentences (and, in the
    /// Info-panel variant, emit bullets of their own).
    func test_windowSummaryInstructions_askForOneSentenceNoLists() {
        let i = AITextActionPromptBuilder.windowSummaryInstructions
        XCTAssertTrue(i.contains("ONE short, complete sentence"))
        XCTAssertTrue(i.lowercased().contains("bullet"))
        XCTAssertNotEqual(i, AITextActionPromptBuilder.summaryInstructions)
        XCTAssertNotEqual(i, AITextActionPromptBuilder.infoSummaryInstructions)
    }

    func test_markdownComposeInstructions_keepTablesVerbatim() {
        let i = AITextActionPromptBuilder.markdownComposeInstructions(hasTable: true)
        XCTAssertFalse(i.isEmpty)
        XCTAssertTrue(i.contains("VERBATIM"))
        XCTAssertTrue(i.lowercased().contains("markdown"))
    }

    func test_markdownComposeInstructions_noTable_forbidsTables() {
        let i = AITextActionPromptBuilder.markdownComposeInstructions(hasTable: false)
        XCTAssertTrue(i.contains("Do NOT use Markdown tables"))
        XCTAssertFalse(i.contains("VERBATIM"))
    }

    func test_prompt_includesOCR() {
        let p = AITextActionPromptBuilder.prompt(ocrText: "Total due $42.00", maxOCRChars: 4_000)
        XCTAssertTrue(p.contains("Total due $42.00"))
    }

    func test_prompt_truncatesOCRToBudget() {
        let big = String(repeating: "k", count: 9_000)
        let p = AITextActionPromptBuilder.prompt(ocrText: big, maxOCRChars: 500)
        XCTAssertLessThan(p.count, 1_000)
    }
}
