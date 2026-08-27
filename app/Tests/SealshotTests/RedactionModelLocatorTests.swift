import XCTest
@testable import Sealshot

final class RedactionModelLocatorTests: XCTestCase {
    func testReturnsNilWhenUnset() {
        let d = UserDefaults(suiteName: "test.redmodel.\(UUID())")!
        XCTAssertNil(RedactionModelLocator.localModelPath(defaults: d, fileExists: { _ in false }))
    }
    func testReturnsOverridePathWhenFileExists() {
        let d = UserDefaults(suiteName: "test.redmodel.\(UUID())")!
        d.set("/models/gliner2", forKey: "RedactionModelPath")
        XCTAssertEqual(RedactionModelLocator.localModelPath(defaults: d, fileExists: { $0 == "/models/gliner2" }), "/models/gliner2")
    }
}
