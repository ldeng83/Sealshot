import XCTest
@testable import Sealshot

final class CollectionImportNamingTests: XCTestCase {
    func test_freeName_usedAsIs() {
        XCTAssertEqual(CollectionImportNaming.resolvedName(base: "Trip", existing: []), "Trip")
    }
    func test_clash_appendsImported() {
        XCTAssertEqual(CollectionImportNaming.resolvedName(base: "Trip", existing: ["Trip"]),
                       "Trip (Imported)")
    }
    func test_doubleClash_appendsNumber() {
        XCTAssertEqual(
            CollectionImportNaming.resolvedName(base: "Trip", existing: ["Trip", "Trip (Imported)"]),
            "Trip (Imported 2)")
        XCTAssertEqual(
            CollectionImportNaming.resolvedName(
                base: "Trip", existing: ["Trip", "Trip (Imported)", "Trip (Imported 2)"]),
            "Trip (Imported 3)")
    }
}
