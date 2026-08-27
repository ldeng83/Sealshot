import XCTest
@testable import Sealshot

final class SummaryGeneratorTests: XCTestCase {

    func test_gating_requiresAiEnabledFmAvailableMissingSummaryAndText() {
        // Happy path: should generate.
        XCTAssertTrue(SummaryGating.shouldGenerate(
            aiEnabled: true, foundationModelAvailable: true,
            summaryPresent: false, ocrText: "Some real text here."))
        // Off when AI disabled.
        XCTAssertFalse(SummaryGating.shouldGenerate(
            aiEnabled: false, foundationModelAvailable: true,
            summaryPresent: false, ocrText: "Some real text here."))
        // Off when FM unavailable.
        XCTAssertFalse(SummaryGating.shouldGenerate(
            aiEnabled: true, foundationModelAvailable: false,
            summaryPresent: false, ocrText: "Some real text here."))
        // Off when a summary already exists.
        XCTAssertFalse(SummaryGating.shouldGenerate(
            aiEnabled: true, foundationModelAvailable: true,
            summaryPresent: true, ocrText: "Some real text here."))
        // Off when there's no/blank OCR text to summarize.
        XCTAssertFalse(SummaryGating.shouldGenerate(
            aiEnabled: true, foundationModelAvailable: true,
            summaryPresent: false, ocrText: "   "))
        XCTAssertFalse(SummaryGating.shouldGenerate(
            aiEnabled: true, foundationModelAvailable: true,
            summaryPresent: false, ocrText: nil))
    }

    // MARK: - isScene exemption (Live Capture)

    /// A scene whose windows carry no readable text at all (photo viewers,
    /// video players, undecodable assets) still gets a summary — the
    /// name-only bullet list `SceneSummarizer` builds from the manifest,
    /// never from `ocrText`. Mirrors `MetadataCoordinator.needsTagBackfill`'s
    /// `isScene` exemption for exactly the same "empty OCR text is not a
    /// terminal dead end for scenes" shape of problem.
    func test_gating_sceneWithEmptyOcrTextIsAllowed() {
        XCTAssertTrue(SummaryGating.shouldGenerate(
            aiEnabled: true, foundationModelAvailable: true,
            summaryPresent: false, ocrText: "", isScene: true))
    }

    /// The exemption is scoped to scenes only: a non-scene capture with blank
    /// OCR text must still be refused. Widening this would mean a pure image
    /// gets summarized with nothing to summarize.
    func test_gating_nonSceneWithEmptyOcrTextStaysRefused() {
        XCTAssertFalse(SummaryGating.shouldGenerate(
            aiEnabled: true, foundationModelAvailable: true,
            summaryPresent: false, ocrText: "", isScene: false))
    }

    /// The terminal rule (a stored summary is never replaced) still applies
    /// to scenes — the `isScene` exemption only widens the empty-text case,
    /// it must not reopen a capture that already has a summary.
    func test_gating_sceneWithExistingSummaryStaysRefused() {
        XCTAssertFalse(SummaryGating.shouldGenerate(
            aiEnabled: true, foundationModelAvailable: true,
            summaryPresent: true, ocrText: "", isScene: true))
    }

    func test_foundationGenerator_neverThrowsAndTextOutcomeIsNonEmpty() async {
        // Environment-robust: the host may or may not have Foundation Models, so
        // the outcome may be .text / .skip / .transient. The guarantee is that
        // summarize never throws and a .text outcome is never empty.
        let out = await FoundationSummaryGenerator().summarize(
            ocrText: "Payment failed. Card declined.")
        if case let .text(s) = out {
            XCTAssertFalse(s.isEmpty, "a .text outcome must be non-empty")
        }
    }

    func test_foundationGenerator_skipsLabelSoup() async {
        // "Label soup" (many short fragments) is unsummarizable → terminal .skip,
        // and the model is never called, so this holds regardless of FM availability.
        let soup = (1...30).map { "Item\($0)" }.joined(separator: "\n")
        let out = await FoundationSummaryGenerator().summarize(ocrText: soup)
        XCTAssertEqual(out, .skip)
    }
}
