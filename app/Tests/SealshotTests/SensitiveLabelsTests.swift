import XCTest
@testable import Sealshot

final class SensitiveLabelsTests: XCTestCase {
    private func labeledValues(_ text: String) -> [String] {
        ContextualDetectors.anchoredMatches(in: text).filter { $0.category == .labeledField }.map(\.text)
    }
    func test_newLabels_redactValue() {
        XCTAssertEqual(labeledValues("MRN: 00123456"), ["00123456"])
        XCTAssertEqual(labeledValues("Routing number: 021000021"), ["021000021"])
        XCTAssertEqual(labeledValues("Policy number = AB-99-1234"), ["AB-99-1234"])
        XCTAssertEqual(labeledValues("Member ID: XYZ7788"), ["XYZ7788"])
        XCTAssertEqual(labeledValues("IBAN: GB29 NWBK 6016 1331 9268 19"), ["GB29 NWBK 6016 1331 9268 19"])
    }
    func test_bareLabelInProse_notMatched() {
        XCTAssertTrue(labeledValues("the policy was updated and the account was reviewed").isEmpty)
    }
}
