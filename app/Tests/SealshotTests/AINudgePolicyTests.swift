import XCTest
@testable import Sealshot

/// The nudge decision: which message (if any) each availability reason
/// produces, and which of them offers a call to action.
///
/// Rule under test — only `.appleIntelligenceOff` is actionable. A Mac that
/// can never run the model gets a statement of fact and no button; nagging it
/// would be user-hostile. Sealshot's own AI toggle outranks every reason.
final class AINudgePolicyTests: XCTestCase {

    func test_available_producesNoMessage() {
        XCTAssertNil(AINudgePolicy.presentation(for: .available, aiToggleOn: true),
                     "nothing to say when the model is working")
    }

    func test_appleIntelligenceOff_isActionable() throws {
        let nudge = try XCTUnwrap(
            AINudgePolicy.presentation(for: .unavailable(.appleIntelligenceOff), aiToggleOn: true))
        XCTAssertTrue(nudge.isActionable,
                      "the user can fix this one in System Settings")
        XCTAssertTrue(nudge.body.contains("Private Cloud Compute"),
                      "the honest trade-off must survive future copy edits")
        XCTAssertTrue(nudge.body.contains("never sent anywhere"),
                      "must state that Sealshot does not upload captures")
    }

    func test_deviceNotEligible_isNotActionable() throws {
        let nudge = try XCTUnwrap(
            AINudgePolicy.presentation(for: .unavailable(.deviceNotEligible), aiToggleOn: true))
        XCTAssertFalse(nudge.isActionable, "there is no action this user can take")
    }

    func test_notSupportedOS_isNotActionable() throws {
        let nudge = try XCTUnwrap(
            AINudgePolicy.presentation(for: .unavailable(.notSupportedOS), aiToggleOn: true))
        XCTAssertFalse(nudge.isActionable, "there is no action this user can take")
    }

    func test_modelNotReady_isNotActionable() throws {
        let nudge = try XCTUnwrap(
            AINudgePolicy.presentation(for: .unavailable(.modelNotReady), aiToggleOn: true))
        XCTAssertFalse(nudge.isActionable, "waiting is not a call to action")
    }

    func test_unavailableForAnotherReason_isNotActionable() throws {
        let nudge = try XCTUnwrap(
            AINudgePolicy.presentation(for: .unavailable(.unavailableForAnotherReason), aiToggleOn: true))
        XCTAssertFalse(nudge.isActionable,
                       "an unrecognized reason must not invent a call to action")
    }

    /// Sealshot's own switch outranks everything: a user who turned the
    /// feature off has already answered the question.
    func test_toggleOff_suppressesAppleIntelligenceEncouragement() throws {
        for status: AIStatus in [.available,
                                 .unavailable(.appleIntelligenceOff),
                                 .unavailable(.deviceNotEligible),
                                 .unavailable(.notSupportedOS),
                                 .unavailable(.modelNotReady),
                                 .unavailable(.unavailableForAnotherReason)] {
            let nudge = try XCTUnwrap(
                AINudgePolicy.presentation(for: status, aiToggleOn: false),
                "toggle-off always explains itself (status: \(status))")
            XCTAssertFalse(nudge.isActionable,
                           "no System Settings button when our own toggle is off")
            XCTAssertFalse(nudge.body.contains("Apple Intelligence"),
                           "no Apple Intelligence pitch when our own toggle is off (status: \(status))")
        }
    }
}
