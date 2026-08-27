import XCTest
@testable import Sealshot

final class StructuredItemsCodableTests: XCTestCase {
    func test_roundTrip() throws {
        var i = StructuredItems()
        i.tables = [StructuredTable(headers: ["A", "B"], rows: [["1", "2"]])]
        i.emails = ["a@b.com"]
        i.formFields = [StructuredField(label: "k", value: "v")]
        i.contacts = [StructuredContact(name: "N", email: "e", phone: "p", organization: "o", title: "t")]
        i.codeBlocks = [StructuredCode(language: "swift", code: "let x = 1")]
        let data = try JSONEncoder().encode(i)
        XCTAssertEqual(try JSONDecoder().decode(StructuredItems.self, from: data), i)
    }
}
