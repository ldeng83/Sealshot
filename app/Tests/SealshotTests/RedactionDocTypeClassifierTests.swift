import XCTest
@testable import Sealshot

final class RedactionDocTypeClassifierTests: XCTestCase {
    private func classify(_ s: String) -> Set<RedactionDocType> {
        RedactionDocTypeClassifier.classify(s)
    }
    func test_identity() {
        XCTAssertEqual(classify("Passport No. ZE000509\nNationality CANADIAN\nIssuing Authority GATINEAU"), [.identity])
    }
    func test_health() {
        XCTAssertEqual(classify("Patient: Jane Doe\nDiagnosis: hypertension\nMRN: 0012"), [.health])
    }
    func test_financial() {
        XCTAssertEqual(classify("Account number: 123\nRouting number: 021000021\nStatement balance"), [.financial])
    }
    func test_multiLabel_idAndFinancial() {
        let r = classify("Passport No. ZE000509 IBAN: GB29 NWBK Account number: 1")
        XCTAssertTrue(r.contains(.identity)); XCTAssertTrue(r.contains(.financial))
    }
    func test_genericProse_empty() {
        XCTAssertTrue(classify("The weather was lovely and we walked to the park.").isEmpty)
    }
    func test_singleWeakAnchor_notEnough() {
        // One regular anchor ("balance") alone must not classify as financial.
        XCTAssertFalse(classify("Your balance is positive today.").contains(.financial))
    }
    func test_financial_balanceSheet() {
        // A literal balance sheet must classify financial ("balance sheet" is strong).
        let r = classify("TEDDY FAB INC.\nBALANCE SHEET\nASSETS\nTotal current assets\n"
            + "LIABILITIES AND SHAREHOLDERS' EQUITY\nRetained earnings\nTreasury stock\nTotal assets")
        XCTAssertTrue(r.contains(.financial))
    }
    func test_financial_statementByRegulars() {
        // No title, but multiple statement terms (≥2 regulars) → financial.
        XCTAssertTrue(classify("Assets:\nLiabilities:\nRevenues:\nCash and cash equivalents").contains(.financial))
    }
}
