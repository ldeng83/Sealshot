import XCTest
@testable import Sealshot

final class ContextualDetectorsTests: XCTestCase {

    private func categories(in text: String) -> [SensitiveCategory] {
        ContextualDetectors.matches(in: text).map(\.category)
    }

    // MARK: - Labeled fields (deterministic)

    func testLabeledField_redactsValueOnly() {
        let line = "Patient: Jane Q Public"
        let matches = ContextualDetectors.matches(in: line).filter { $0.category == .labeledField }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].text, "Jane Q Public")
        // Only the VALUE is reported, not the "Patient:" label.
        XCTAssertEqual(String(Array(line)[matches[0].range]), "Jane Q Public")
    }

    func testLabeledField_dobAccountSalary() {
        XCTAssertTrue(ContextualDetectors.matches(in: "DOB: 1980-05-12")
            .contains { $0.category == .labeledField && $0.text == "1980-05-12" })
        XCTAssertTrue(ContextualDetectors.matches(in: "Account #: 12345678")
            .contains { $0.category == .labeledField && $0.text == "12345678" })
        XCTAssertTrue(ContextualDetectors.matches(in: "Salary: $120,000")
            .contains { $0.category == .labeledField && $0.text.contains("120,000") })
    }

    func testLabeledField_bareLabelInProseIgnored() {
        // No separator → not a labeled field.
        XCTAssertFalse(categories(in: "the patient was discharged today").contains(.labeledField))
    }

    // MARK: - Framework-backed smoke (may vary across OS NER models)

    func testNER_detectsANamedEntity() {
        let cats = categories(in: "Please email Tim Cook at Apple about the report")
        XCTAssertTrue(cats.contains(.personName) || cats.contains(.organizationName),
                      "expected a name entity among \(cats)")
    }

    func testPostalAddress_detected() {
        let cats = categories(in: "Ship to 1 Infinite Loop, Cupertino, CA 95014 please")
        XCTAssertTrue(cats.contains(.postalAddress), "expected a postal address among \(cats)")
    }
}
