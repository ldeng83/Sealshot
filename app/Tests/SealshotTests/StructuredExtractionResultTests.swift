import XCTest
@testable import Sealshot

final class StructuredExtractionResultTests: XCTestCase {

    func test_isEmpty_trueWhenNothingExtracted() {
        XCTAssertTrue(StructuredExtractionResult.isEmpty(StructuredItems()))
    }

    func test_isEmpty_falseWhenAnyTypePresent() {
        var items = StructuredItems(); items.urls = ["https://x.com"]
        XCTAssertFalse(StructuredExtractionResult.isEmpty(items))
    }

    func test_table_rendersAsMarkdown() {
        var items = StructuredItems()
        items.tables = [StructuredTable(headers: ["Name", "Qty"], rows: [["Apple", "3"]])]
        let g = StructuredExtractionResult.groups(from: items)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].title, "Tables")
        XCTAssertEqual(g[0].body, "| Name | Qty |\n| --- | --- |\n| Apple | 3 |")
    }

    func test_contact_rendersNonEmptyFieldsOnly() {
        var items = StructuredItems()
        items.contacts = [StructuredContact(name: "Jane Doe", email: "jane@x.com",
                                            phone: "555-1234", organization: "Acme", title: "Engineer")]
        let g = StructuredExtractionResult.groups(from: items)
        XCTAssertEqual(g[0].body, "Jane Doe\njane@x.com · 555-1234\nAcme — Engineer")
    }

    func test_contact_skipsBlankLines() {
        var items = StructuredItems()
        items.contacts = [StructuredContact(name: "Bob", email: "", phone: "", organization: "", title: "")]
        XCTAssertEqual(StructuredExtractionResult.groups(from: items)[0].body, "Bob")
    }

    func test_code_rendersFenced() {
        var items = StructuredItems()
        items.codeBlocks = [StructuredCode(language: "swift", code: "print(1)")]
        XCTAssertEqual(StructuredExtractionResult.groups(from: items)[0].body, "```swift\nprint(1)\n```")
    }

    func test_groups_inCanonicalOrder_emptyOmitted() {
        var items = StructuredItems()
        items.urls = ["https://x.com"]
        items.tables = [StructuredTable(headers: ["A"], rows: [["1"]])]
        let titles = StructuredExtractionResult.groups(from: items).map(\.title)
        XCTAssertEqual(titles, ["Tables", "URLs"])  // Tables before URLs; Contacts/etc omitted
    }

    func test_copyAll_concatenatesGroupsWithHeadings() {
        let groups = [ExtractedGroup(title: "URLs", body: "- https://x.com"),
                      ExtractedGroup(title: "Dates", body: "- 2026-06-21")]
        XCTAssertEqual(StructuredExtractionResult.copyAllText(groups),
                       "## URLs\n- https://x.com\n\n## Dates\n- 2026-06-21")
    }

    // MARK: - New field tests (emails, phones, addresses, money)

    func test_emails_renderAsBullets() {
        var items = StructuredItems()
        items.emails = ["alice@example.com", "bob@example.com"]
        let g = StructuredExtractionResult.groups(from: items)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].title, "Emails")
        XCTAssertEqual(g[0].body, "- alice@example.com\n- bob@example.com")
    }

    func test_phones_renderAsBullets() {
        var items = StructuredItems()
        items.phones = ["+1 (800) 555-0100", "555-1234"]
        let g = StructuredExtractionResult.groups(from: items)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].title, "Phones")
        XCTAssertEqual(g[0].body, "- +1 (800) 555-0100\n- 555-1234")
    }

    func test_addresses_renderAsBullets() {
        var items = StructuredItems()
        items.addresses = ["123 Main St, Springfield, IL 62701"]
        let g = StructuredExtractionResult.groups(from: items)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].title, "Addresses")
        XCTAssertEqual(g[0].body, "- 123 Main St, Springfield, IL 62701")
    }

    func test_money_renderAsBullets() {
        var items = StructuredItems()
        items.money = ["$1,234.56", "€99.00"]
        let g = StructuredExtractionResult.groups(from: items)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].title, "Money")
        XCTAssertEqual(g[0].body, "- $1,234.56\n- €99.00")
    }

    func test_isEmpty_falseWhenOnlyMoneyPresent() {
        var items = StructuredItems()
        items.money = ["$42.00"]
        XCTAssertFalse(StructuredExtractionResult.isEmpty(items))
    }

    func test_groups_canonicalOrderAllTypes() {
        var items = StructuredItems()
        items.tables = [StructuredTable(headers: ["A"], rows: [["1"]])]
        items.contacts = [StructuredContact(name: "Alice", email: "", phone: "", organization: "", title: "")]
        items.codeBlocks = [StructuredCode(language: "swift", code: "let x = 1")]
        items.formFields = [StructuredField(label: "Name", value: "Bob")]
        items.urls = ["https://example.com"]
        items.emails = ["alice@example.com"]
        items.phones = ["555-0100"]
        items.addresses = ["123 Main St"]
        items.money = ["$9.99"]
        items.dates = ["2026-06-22"]
        items.stackTraces = ["frame 0: crash()"]
        let titles = StructuredExtractionResult.groups(from: items).map(\.title)
        XCTAssertEqual(titles, ["Tables", "Contacts", "Code", "Fields",
                                 "URLs", "Emails", "Phones", "Addresses", "Money",
                                 "Dates", "Stack Traces"])
    }
}
