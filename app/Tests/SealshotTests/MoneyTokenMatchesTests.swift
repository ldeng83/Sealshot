import XCTest
@testable import Sealshot

final class MoneyTokenMatchesTests: XCTestCase {
    private func texts(_ s: String) -> [String] { SensitiveTextRules.moneyTokenMatches(in: s).map(\.text) }

    func test_matchesMoneyForms() {
        XCTAssertEqual(texts("Cash $ 100,000"), ["$ 100,000"])
        XCTAssertEqual(texts("Treasury stock (2,000)"), ["(2,000)"])
        XCTAssertEqual(texts("Less amortization (200)"), ["(200)"])
        XCTAssertEqual(texts("Deferred revenue 2,000"), ["2,000"])
        XCTAssertEqual(texts("Total 5,000.00 due"), ["5,000.00"])
        XCTAssertEqual(texts("Item $29.99"), ["$29.99"])
        XCTAssertEqual(texts("Equity 197,100"), ["197,100"])
    }
    func test_rejectsNonMoney() {
        // Bare integers (year/day) and hyphen-separated numbers carry no money signal.
        XCTAssertTrue(texts("December 31, 2100").isEmpty)
        XCTAssertTrue(texts("call 555-1234").isEmpty)
        XCTAssertTrue(texts("page 42").isEmpty)
    }
    func test_rangeMapsToText() {
        let line = "x (5,000) y"
        let m = SensitiveTextRules.moneyTokenMatches(in: line)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(String(Array(line)[m[0].range]), "(5,000)")
    }
}
