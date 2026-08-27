import XCTest
@testable import Sealshot

final class RedactionDocTypeLabelsTests: XCTestCase {
    func test_emptySet_isFullUnion() {
        XCTAssertEqual(RedactionCategories.entityTypes(for: []), RedactionCategories.entityTypes)
    }
    func test_allTypes_equalsUnion_noLabelLost() {
        // core ∪ all type-specific must equal the canonical union exactly.
        XCTAssertEqual(Set(RedactionCategories.entityTypes(for: Set(RedactionDocType.allCases))),
                       Set(RedactionCategories.entityTypes))
    }
    func test_everyResultIncludesCore() {
        for combo in [[.identity], [.health], [.financial], [.identity, .financial]] as [Set<RedactionDocType>] {
            let got = Set(RedactionCategories.entityTypes(for: combo))
            XCTAssertTrue(Set(RedactionCategories.coreEntityTypes).isSubset(of: got))
        }
    }
    func test_identity_hasPassportLabels_andNoDuplicates() {
        let got = RedactionCategories.entityTypes(for: [.identity])
        XCTAssertTrue(got.contains("passport number"))
        XCTAssertTrue(got.contains("nationality"))
        XCTAssertEqual(got.count, Set(got).count, "no duplicate labels")
    }
}
