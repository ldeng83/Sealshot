import XCTest
@testable import Sealshot

final class MetadataGeneratorChoiceTests: XCTestCase {

    func test_foundationModel_whenEnabledAndAvailable() {
        XCTAssertEqual(chooseMetadataGenerator(aiEnabled: true, foundationModelAvailable: true),
                       .foundationModel)
    }

    func test_ruleBased_whenEnabledButModelUnavailable() {
        XCTAssertEqual(chooseMetadataGenerator(aiEnabled: true, foundationModelAvailable: false),
                       .ruleBased)
    }

    func test_ruleBased_whenDisabled_regardlessOfAvailability() {
        XCTAssertEqual(chooseMetadataGenerator(aiEnabled: false, foundationModelAvailable: true),
                       .ruleBased)
        XCTAssertEqual(chooseMetadataGenerator(aiEnabled: false, foundationModelAvailable: false),
                       .ruleBased)
    }

    /// The rule-based generator must satisfy the async `MetadataGenerating`
    /// interface — it's the fallback the coordinator awaits when the model is off.
    func test_ruleBasedGenerator_conformsToAsyncProtocol() async {
        let generator: MetadataGenerating = RuleBasedMetadataGenerator()
        let signals = MetadataSignals(ocrText: "Traceback: fatal error",
                                      sourceApp: "Terminal", windowTitle: nil,
                                      captureDate: Date(timeIntervalSince1970: 0),
                                      imageWidth: 10, imageHeight: 10)
        let md = await generator.makeMetadata(for: signals)
        XCTAssertEqual(md.category, .error)
    }
}
