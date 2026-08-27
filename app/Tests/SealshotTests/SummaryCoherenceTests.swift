import XCTest
@testable import Sealshot

final class SummaryCoherenceTests: XCTestCase {

    func test_prose_isSummarizable() {
        let text = """
        Quarterly revenue grew 12% to $4.2M driven by the new enterprise tier.
        Churn fell to 1.8% after the onboarding redesign shipped in March.
        The board approved hiring two more engineers for the platform team.
        """
        XCTAssertTrue(SummaryCoherence.isSummarizable(text))
    }

    func test_labelSoup_isNotSummarizable() {
        // A maps/dashboard screenshot: many tiny fragments, very few words/line.
        let lines = ["B3 Gas", "::", "1h 25m", "Your location", "Belmont", "Chelsea",
                     "Deer Island", "Boston", "Quincy", "Milton", "Dedham", "Hull",
                     "1 hr 28 min", "22.8 miles", "Cambridge", "saved", "20", "Brookline",
                     "Boston Light", "ROXBURY", "Castle Island", "Needham", "Webb", "Haiti",
                     "Quincy Bay", "Winthrop", "Options", "Recents", "Layers", "Get app"]
        XCTAssertFalse(SummaryCoherence.isSummarizable(lines.joined(separator: "\n")))
    }

    func test_fewShortLines_isSummarizable() {
        // Below the line-count threshold → don't suppress (e.g. a short note).
        let text = "Error 500\nServer timeout\nRetry in 30s"
        XCTAssertTrue(SummaryCoherence.isSummarizable(text))
    }

    func test_manyButWordyLines_isSummarizable() {
        // Many lines, but each a real sentence → still summarizable.
        let line = "This row describes one transaction with a date amount and a memo field"
        let text = Array(repeating: line, count: 25).joined(separator: "\n")
        XCTAssertTrue(SummaryCoherence.isSummarizable(text))
    }

    func test_denseLabelValueForm_isSummarizable() {
        // A label:value document (e.g. a medical record): many short lines
        // averaging ~2 words/line. Real content, not single-word map soup, so
        // the lowered coherence bar lets it through to the summarizer.
        let lines = ["Prepared For Ellen", "Birthday 1960", "Gender Female",
                     "Ethnicity Asian", "Language English", "Status Married",
                     "Allergy BeeStings", "Severity Severe", "Reaction Anaphylaxis",
                     "Allergy Penicillin", "Severity Moderate", "Reaction Hives",
                     "Medication Terbutaline", "Type Inhaler", "Refills Yes",
                     "Dose 2puffs", "Rate 2x", "Provider Ashby",
                     "Immunization Influenza", "Date 2013", "Provider Walgreens",
                     "Booster Annually", "Phone 5551200", "Address Portland"]
        XCTAssertTrue(SummaryCoherence.isSummarizable(lines.joined(separator: "\n")))
    }
}
