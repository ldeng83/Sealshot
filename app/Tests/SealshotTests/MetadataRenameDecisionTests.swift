import XCTest
@testable import Sealshot

final class MetadataRenameDecisionTests: XCTestCase {
    func testRenamesWhenTitleAndAppPresent() {
        XCTAssertTrue(MetadataCoordinator.shouldRenameForTitle(
            encryptionEnabled: true, preferenceEnabled: true, title: "Report", app: "Xcode"))
    }
    /// The toggle must work even when no title is available (AI metadata off or
    /// it produced nothing): the app name alone is enough to rename.
    func testRenamesWhenOnlyAppPresent() {
        XCTAssertTrue(MetadataCoordinator.shouldRenameForTitle(
            encryptionEnabled: true, preferenceEnabled: true, title: nil, app: "Safari"))
    }
    func testRenamesWhenOnlyTitlePresent() {
        XCTAssertTrue(MetadataCoordinator.shouldRenameForTitle(
            encryptionEnabled: true, preferenceEnabled: true, title: "Report", app: nil))
    }
    func testSkipsWhenNeitherTitleNorApp() {
        XCTAssertFalse(MetadataCoordinator.shouldRenameForTitle(
            encryptionEnabled: true, preferenceEnabled: true, title: "  ", app: "  "))
    }
    func testSkipsWhenEncryptionOff() {
        XCTAssertFalse(MetadataCoordinator.shouldRenameForTitle(
            encryptionEnabled: false, preferenceEnabled: true, title: "Report", app: "Xcode"))
    }
    func testSkipsWhenPreferenceOff() {
        XCTAssertFalse(MetadataCoordinator.shouldRenameForTitle(
            encryptionEnabled: true, preferenceEnabled: false, title: "Report", app: "Xcode"))
    }

    // MARK: - AI name-generation gating (drives the "refining" spinner)

    func testWillGenerateAIName_allConditionsMet() {
        XCTAssertTrue(MetadataCoordinator.willGenerateAIName(
            encryptionEnabled: true, preferenceEnabled: true,
            aiEnabled: true, foundationModelAvailable: true))
    }
    func testWillGenerateAIName_falseWhenAIDisabled() {
        XCTAssertFalse(MetadataCoordinator.willGenerateAIName(
            encryptionEnabled: true, preferenceEnabled: true,
            aiEnabled: false, foundationModelAvailable: true))
    }
    func testWillGenerateAIName_falseWhenModelUnavailable() {
        XCTAssertFalse(MetadataCoordinator.willGenerateAIName(
            encryptionEnabled: true, preferenceEnabled: true,
            aiEnabled: true, foundationModelAvailable: false))
    }
    func testWillGenerateAIName_falseWhenPreferenceOff() {
        XCTAssertFalse(MetadataCoordinator.willGenerateAIName(
            encryptionEnabled: true, preferenceEnabled: false,
            aiEnabled: true, foundationModelAvailable: true))
    }
    func testWillGenerateAIName_falseWhenEncryptionOff() {
        XCTAssertFalse(MetadataCoordinator.willGenerateAIName(
            encryptionEnabled: false, preferenceEnabled: true,
            aiEnabled: true, foundationModelAvailable: true))
    }

    // MARK: - Title-row spinner

    // `NameGenerationRegistry` marks the whole metadata pipeline as in flight,
    // not just AI naming: `ensureTags` enters it whenever ANY generator exists,
    // and on a Mac with no Neural Engine that is the rule-based one. The title
    // spinner means "this filename isn't final yet", so following the registry
    // alone made it promise a refinement that was never coming — and sit there
    // for the length of the OCR, which is exactly the slow part on those Macs.

    func testTitleRefining_hiddenWhenNoAINameIsComing() {
        XCTAssertFalse(MetadataCoordinator.shouldShowTitleRefining(
            pipelineInFlight: true, willGenerateAIName: false),
            "rule-based naming is already final — nothing to wait for")
    }

    func testTitleRefining_shownWhileAnAINameIsBeingGenerated() {
        XCTAssertTrue(MetadataCoordinator.shouldShowTitleRefining(
            pipelineInFlight: true, willGenerateAIName: true))
    }

    func testTitleRefining_hiddenWhenThePipelineIsIdle() {
        XCTAssertFalse(MetadataCoordinator.shouldShowTitleRefining(
            pipelineInFlight: false, willGenerateAIName: true))
    }

    // MARK: - Title resolution (AI title preferred, window title fallback)

    func testRenameTitlePrefersAITitle() {
        XCTAssertEqual(MetadataCoordinator.renameTitle(
            aiTitle: "Generated Title", windowTitle: "Window Title"), "Generated Title")
    }
    func testRenameTitleFallsBackToWindowTitle() {
        XCTAssertEqual(MetadataCoordinator.renameTitle(
            aiTitle: "", windowTitle: "Window Title"), "Window Title")
    }
    func testRenameTitleFallsBackWhenAINil() {
        XCTAssertEqual(MetadataCoordinator.renameTitle(
            aiTitle: nil, windowTitle: "Window Title"), "Window Title")
    }
    func testRenameTitleNilWhenBothEmpty() {
        XCTAssertNil(MetadataCoordinator.renameTitle(aiTitle: "  ", windowTitle: nil))
    }
}
