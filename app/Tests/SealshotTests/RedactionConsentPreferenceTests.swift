import XCTest
@testable import Sealshot

final class RedactionConsentPreferenceTests: XCTestCase {
    func testPromptsOnlyWhenSupportedReadyMissingAndNotAsked() {
        XCTAssertTrue(RedactionConsentPreference.shouldPrompt(appleSilicon: true, aiEnabled: true, modelReady: false, asked: false))
        XCTAssertFalse(RedactionConsentPreference.shouldPrompt(appleSilicon: true, aiEnabled: true, modelReady: true, asked: false))  // already have it
        XCTAssertFalse(RedactionConsentPreference.shouldPrompt(appleSilicon: true, aiEnabled: true, modelReady: false, asked: true))  // don't nag
        XCTAssertFalse(RedactionConsentPreference.shouldPrompt(appleSilicon: false, aiEnabled: true, modelReady: false, asked: false))
        XCTAssertFalse(RedactionConsentPreference.shouldPrompt(appleSilicon: true, aiEnabled: false, modelReady: false, asked: false))
    }
}
