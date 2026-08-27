import XCTest
@testable import Sealshot

@MainActor
final class RedactionDefaultKeepTests: XCTestCase {
    private func det(_ cat: SensitiveCategory, _ conf: Double, label: String? = nil) -> Detection {
        Detection(category: cat, snippet: "x", confidence: conf, rects: [], customLabel: label)
    }
    func test_highRiskCategory_keptBelowThreshold() {
        XCTAssertTrue(EditorState.defaultKept(det(.creditCard, 0.6)))
        XCTAssertTrue(EditorState.defaultKept(det(.machineReadableZone, 0.3)))
    }
    func test_highRiskLabel_keptBelowThreshold() {
        XCTAssertTrue(EditorState.defaultKept(det(.contextual, 0.6, label: "passport number")))
        XCTAssertTrue(EditorState.defaultKept(det(.contextual, 0.5, label: "Credit card")))
    }
    func test_lowStakes_belowThreshold_notKept() {
        XCTAssertFalse(EditorState.defaultKept(det(.personName, 0.45)))
        XCTAssertFalse(EditorState.defaultKept(det(.contextual, 0.5, label: "organization")))
    }
    func test_threshold_stillKeptForNonHighRisk() {
        XCTAssertTrue(EditorState.defaultKept(det(.personName, 0.8)))
    }
    func test_isHighRiskLabel() {
        XCTAssertTrue(EditorState.isHighRiskLabel("National ID"))
        XCTAssertFalse(EditorState.isHighRiskLabel("person name"))
        XCTAssertFalse(EditorState.isHighRiskLabel(nil as String?))
    }
    func test_phiAndContactLabels_keptBelowThreshold() {
        XCTAssertTrue(EditorState.defaultKept(det(.contextual, 0.55, label: "mailing address")))
        XCTAssertTrue(EditorState.defaultKept(det(.contextual, 0.57, label: "medical condition")))
        XCTAssertTrue(EditorState.defaultKept(det(.contextual, 0.6, label: "medication")))
    }
    func test_emailPhoneCategory_keptBelowThreshold() {
        XCTAssertTrue(EditorState.defaultKept(det(.email, 0.36)))
        XCTAssertTrue(EditorState.defaultKept(det(.phone, 0.30)))
        XCTAssertTrue(EditorState.defaultKept(det(.postalAddress, 0.4)))
    }
    func test_newKeywords_isHighRiskLabel() {
        XCTAssertTrue(EditorState.isHighRiskLabel("Email address"))
        XCTAssertTrue(EditorState.isHighRiskLabel("mailing address"))
        XCTAssertTrue(EditorState.isHighRiskLabel("medical condition"))
        XCTAssertFalse(EditorState.isHighRiskLabel("organization"))
    }
    func test_money_keptOnFinancialDoc() {
        XCTAssertTrue(EditorState.defaultKept(det(.contextual, 0.5, label: "money amount"), financialDocument: true))
    }
    func test_money_notKeptOnNonFinancialDoc() {
        XCTAssertFalse(EditorState.defaultKept(det(.contextual, 0.5, label: "money amount"), financialDocument: false))
    }
    func test_financialFlag_doesNotLeakToNonMoney() {
        XCTAssertFalse(EditorState.defaultKept(det(.personName, 0.45, label: "person name"), financialDocument: true))
    }
    func test_highRisk_unaffectedByFinancialFlag() {
        XCTAssertTrue(EditorState.defaultKept(det(.creditCard, 0.6), financialDocument: false))
    }
    func test_isMoneyAmount() {
        XCTAssertTrue(EditorState.isMoneyAmount(det(.contextual, 0.5, label: "money amount")))
        XCTAssertTrue(EditorState.isMoneyAmount(det(.contextual, 0.5, label: "Money Amount")))
        XCTAssertFalse(EditorState.isMoneyAmount(det(.contextual, 0.5, label: "organization")))
        XCTAssertFalse(EditorState.isMoneyAmount(det(.personName, 0.5)))
    }
}
