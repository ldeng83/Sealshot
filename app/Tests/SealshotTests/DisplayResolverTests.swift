import XCTest
import CoreGraphics
@testable import Sealshot

final class DisplayResolverTests: XCTestCase {

    func test_firstMatching_returnsPairedValue() {
        let pairs: [(CGDirectDisplayID, String)] = [(1, "a"), (2, "b"), (3, "c")]
        XCTAssertEqual(DisplayResolver.first(matching: 2, in: pairs), "b")
        XCTAssertEqual(DisplayResolver.first(matching: 1, in: pairs), "a")
    }

    func test_firstMatching_nilWhenAbsent() {
        let pairs: [(CGDirectDisplayID, String)] = [(1, "a"), (2, "b")]
        XCTAssertNil(DisplayResolver.first(matching: 99, in: pairs))
        XCTAssertNil(DisplayResolver.first(matching: 0, in: []))
    }
}
