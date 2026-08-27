import XCTest
@testable import Sealshot

final class ExtractionViewsTests: XCTestCase {

    func test_csv_joinsTables() {
        var i = StructuredItems()
        i.tables = [StructuredTable(headers: ["A", "B"], rows: [["1", "2"]]),
                    StructuredTable(headers: ["C"], rows: [["3"]])]
        let csv = ExtractionViews.csv(i)
        XCTAssertTrue(csv.contains("A,B"))
        XCTAssertTrue(csv.contains("1,2"))
        XCTAssertTrue(csv.contains("C"))
    }

    func test_csv_emptyWhenNoTables() {
        XCTAssertTrue(ExtractionViews.csv(StructuredItems()).isEmpty)
    }

    func test_json_isPrettyAndDecodes() throws {
        var i = StructuredItems(); i.emails = ["a@b.com"]
        let s = ExtractionViews.json(i)
        XCTAssertTrue(s.contains("a@b.com"))
        XCTAssertTrue(s.contains("\n"))
        XCTAssertNoThrow(try JSONDecoder().decode(StructuredItems.self, from: Data(s.utf8)))
    }
}
