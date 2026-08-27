import XCTest
@testable import Sealshot

final class RedactionCategoriesTests: XCTestCase {
    func testEntityTypes_nonEmpty_lowercased() {
        XCTAssertFalse(RedactionCategories.entityTypes.isEmpty)
        XCTAssertTrue(RedactionCategories.entityTypes.contains("email address"))
    }
    func testKnownLabelsMap_caseInsensitive() {
        XCTAssertEqual(RedactionCategories.category(forEngineLabel: "Email Address"), .email)
        XCTAssertEqual(RedactionCategories.category(forEngineLabel: "phone number"), .phone)
        XCTAssertEqual(RedactionCategories.category(forEngineLabel: "social security number"), .ssn)
    }
    func testUnknownLabel_returnsNil() {
        XCTAssertNil(RedactionCategories.category(forEngineLabel: "loyalty number"))
    }
}
