import XCTest
@testable import Sealshot

final class DataDetectorTierTests: XCTestCase {

    func test_detectsUrlPhoneDate() {
        let text = "Visit https://example.com or call 415-555-0199 on Jan 5, 2026."
        let r = DataDetectorTier.detect(in: text)
        XCTAssertTrue(r.urls.contains { $0.contains("example.com") }, "got urls \(r.urls)")
        XCTAssertFalse(r.phones.isEmpty, "expected a phone")
        XCTAssertFalse(r.dates.isEmpty, "expected a date")
    }

    func test_emptyWhenNone() {
        let r = DataDetectorTier.detect(in: "just words here")
        XCTAssertTrue(r.urls.isEmpty && r.phones.isEmpty && r.addresses.isEmpty && r.dates.isEmpty)
    }

    func test_dedupesRepeats() {
        let text = "mail https://x.com then https://x.com again"
        let r = DataDetectorTier.detect(in: text)
        XCTAssertEqual(r.urls.filter { $0.contains("x.com") }.count, 1)
    }
}
