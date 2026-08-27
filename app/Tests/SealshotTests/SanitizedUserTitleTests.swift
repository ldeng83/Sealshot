import XCTest
@testable import Sealshot

final class SanitizedUserTitleTests: XCTestCase {
    func testTrimsWhitespace() {
        XCTAssertEqual(sanitizedUserTitle("  Hello  "), "Hello")
    }
    func testEmptyBecomesNil() {
        XCTAssertNil(sanitizedUserTitle("   "))
        XCTAssertNil(sanitizedUserTitle(""))
    }
}
