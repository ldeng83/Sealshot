import XCTest
@testable import Sealshot

final class ContentTypeLabelTests: XCTestCase {
    func testMapsKnownCategories() {
        XCTAssertEqual(ContentTypeLabel.label(for: .error), "Error")
        XCTAssertEqual(ContentTypeLabel.label(for: .code), "Code")
        XCTAssertEqual(ContentTypeLabel.label(for: .design), "Design")
        XCTAssertEqual(ContentTypeLabel.label(for: .document), "Document")
        XCTAssertEqual(ContentTypeLabel.label(for: .dashboard), "Dashboard")
        XCTAssertEqual(ContentTypeLabel.label(for: .chat), "Conversation")
        XCTAssertEqual(ContentTypeLabel.label(for: .settings), "Settings")
        XCTAssertEqual(ContentTypeLabel.label(for: .receipt), "Receipt")
    }
    func testOtherHasNoLabel() {
        XCTAssertNil(ContentTypeLabel.label(for: .other))
    }
}
