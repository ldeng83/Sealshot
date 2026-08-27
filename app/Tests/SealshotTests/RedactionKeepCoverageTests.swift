import XCTest
@testable import Sealshot

/// Locks the always-keep policy against GLiNER2's full label vocabulary: every
/// catastrophic-leak / PII label the model can emit must be checked by default at
/// any confidence; deliberately lower-stakes labels stay threshold-gated. This
/// would have caught the `identity document number` gap.
@MainActor
final class RedactionKeepCoverageTests: XCTestCase {
    // Build a detection the way `engineDetections` maps a model label.
    private func engineDet(_ label: String, _ conf: Double) -> Detection {
        let mapped = RedactionCategories.category(forEngineLabel: label)
        return Detection(category: mapped ?? .contextual, snippet: "value", confidence: conf,
                         rects: [], customLabel: mapped == nil ? label : nil)
    }
    /// Labels that MUST be checked by default regardless of confidence.
    private let alwaysKeep = [
        "email address", "phone number", "mailing address", "social security number",
        "bank account number", "credit card number", "medical condition", "medication",
        "api key", "password", "passport number", "identity document number",
        "driver's license number",
    ]
    /// Deliberately threshold-gated (lower-stakes / policy) — NOT kept at low confidence.
    private let thresholdGated = ["date of issue", "place of birth", "nationality", "ip address"]

    func test_alwaysKeepLabels_keptAtLowConfidence() {
        for l in alwaysKeep {
            XCTAssertTrue(EditorState.defaultKept(engineDet(l, 0.1), financialDocument: false),
                          "\(l) must be always-kept")
        }
    }
    func test_thresholdGatedLabels_notKeptAtLowConfidence() {
        for l in thresholdGated {
            XCTAssertFalse(EditorState.defaultKept(engineDet(l, 0.1), financialDocument: false),
                           "\(l) should be opt-in (threshold-gated) at low confidence")
        }
    }
    func test_identityDocument_isHighRiskLabel() {
        XCTAssertTrue(EditorState.isHighRiskLabel("identity document number"))
    }
}
