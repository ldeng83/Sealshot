import XCTest
@testable import Sealshot

final class TokenOccurrencesTests: XCTestCase {
    func test_findsRepeatedValue() {
        XCTAssertEqual(tokenOccurrences(of: "10,000", in: "Investments 10,000 and 10,000").count, 2)
    }
    func test_rejectsFragmentInsideLargerNumber() {
        // "200" must NOT match inside "200,000"; only the standalone "(200)".
        let r = tokenOccurrences(of: "200", in: "(200) and 200,000")
        XCTAssertEqual(r.count, 1)
    }
    func test_rejectsSubword() {
        XCTAssertEqual(tokenOccurrences(of: "John", in: "John and Johnson").count, 1)
    }
    func test_wholeTokenWithSymbols() {
        XCTAssertEqual(tokenOccurrences(of: "10,000", in: "$10,000").count, 1)
        XCTAssertEqual(tokenOccurrences(of: "2,000", in: "(2,000)").count, 1)
        XCTAssertEqual(tokenOccurrences(of: "5,000.00", in: "Total 5,000.00 due").count, 1)
    }
    func test_rejectsDecimalFragment() {
        // "5,000" must NOT match inside "5,000.00".
        XCTAssertEqual(tokenOccurrences(of: "5,000", in: "5,000.00").count, 0)
    }
    func test_empty() {
        XCTAssertEqual(tokenOccurrences(of: "", in: "abc"), [])
        XCTAssertEqual(tokenOccurrences(of: "x", in: ""), [])
    }
}
