import XCTest
@testable import Sealshot

final class CrockfordCodeTests: XCTestCase {
    func testFormatAndLength() {
        let code = CrockfordCode.generate(groups: 4, groupSize: 5)
        let groups = code.split(separator: "-")
        XCTAssertEqual(groups.count, 4)
        XCTAssertTrue(groups.allSatisfy { $0.count == 5 })
        XCTAssertEqual(code.count, 4 * 5 + 3)   // 20 chars + 3 dashes
    }

    func testOnlyUsesUnambiguousAlphabet() {
        let allowed = Set(CrockfordCode.alphabet)
        let code = CrockfordCode.generate(groups: 6, groupSize: 5)
        for ch in code where ch != "-" {
            XCTAssertTrue(allowed.contains(ch), "unexpected char \(ch)")
        }
        XCTAssertFalse(code.contains { "01OILU".contains($0) })
    }

    func testSuccessiveCallsDiffer() {
        XCTAssertNotEqual(CrockfordCode.generate(groups: 5, groupSize: 5),
                          CrockfordCode.generate(groups: 5, groupSize: 5))
    }

    func testRecoveryCodeStillTwentyFiveChars() {
        let code = RecoveryKey.generateCode()
        XCTAssertEqual(code.split(separator: "-").count, 5)
        XCTAssertEqual(code.replacingOccurrences(of: "-", with: "").count, 25)
    }
}
