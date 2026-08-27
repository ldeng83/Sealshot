import XCTest
@testable import Sealshot

@MainActor
final class DetectionSanityRelabelTests: XCTestCase {
    private func det(_ category: SensitiveCategory, _ snippet: String, customLabel: String?, conf: Double = 0.9) -> Detection {
        Detection(category: category, snippet: snippet, confidence: conf, rects: [], customLabel: customLabel)
    }

    // MARK: classifiers — match
    func test_isLogTimestamp_matches() {
        XCTAssertTrue(DetectionRelabel.isLogTimestamp("2025-05-16T14:18:12.123Z"))
        XCTAssertTrue(DetectionRelabel.isLogTimestamp("2024-05-21 10:12 UTC"))
        XCTAssertTrue(DetectionRelabel.isLogTimestamp("May 23, 11:41:28"))
    }
    func test_isHostnameOrPath_matches() {
        XCTAssertTrue(DetectionRelabel.isHostnameOrPath("sre@host-320"))
        XCTAssertTrue(DetectionRelabel.isHostnameOrPath("devops@workstation"))
        XCTAssertTrue(DetectionRelabel.isHostnameOrPath("~/ops"))
        XCTAssertTrue(DetectionRelabel.isHostnameOrPath("ssh://box/path"))
    }
    func test_isServiceName_matches() {
        XCTAssertTrue(DetectionRelabel.isServiceName("auth-service"))
        XCTAssertTrue(DetectionRelabel.isServiceName("payments-api"))
        XCTAssertTrue(DetectionRelabel.isServiceName("user-svc"))
        XCTAssertTrue(DetectionRelabel.isServiceName("prod-cluster"))
        XCTAssertTrue(DetectionRelabel.isServiceName("claims-service-7c9d5f6d8b"))
    }

    // MARK: classifiers — reject (real PII must NOT match)
    func test_classifiers_rejectRealValues() {
        XCTAssertFalse(DetectionRelabel.isLogTimestamp("2025-05-16"))          // bare issue date
        XCTAssertFalse(DetectionRelabel.isHostnameOrPath("123 Main St, Springfield, IL 62704"))
        XCTAssertFalse(DetectionRelabel.isHostnameOrPath("jane@example.com"))  // real email (has TLD dot)
        XCTAssertFalse(DetectionRelabel.isServiceName("TEDDY FAB INC."))
        XCTAssertFalse(DetectionRelabel.isServiceName("Adobe Systems"))
        XCTAssertFalse(DetectionRelabel.isServiceName("Acme Corp"))
        XCTAssertFalse(DetectionRelabel.isServiceName("claims-corp"))          // corp deliberately excluded
    }

    // MARK: corrected() relabels mislabels, leaves real PII alone
    func test_corrected_downranksMislabels() {
        let input = [
            det(.contextual, "2025-05-16T14:18:12Z", customLabel: "date of issue"),
            det(.postalAddress, "sre@host-320", customLabel: nil),
            det(.organizationName, "auth-service", customLabel: nil),
        ]
        let out = DetectionRelabel.corrected(input)
        XCTAssertEqual(out[0].customLabel, "timestamp")
        XCTAssertEqual(out[1].customLabel, "hostname")
        XCTAssertEqual(out[1].category, .contextual)           // shed the high-risk postalAddress
        XCTAssertEqual(out[2].customLabel, "service name")
        XCTAssertEqual(out[2].category, .contextual)
    }
    func test_corrected_leavesRealPiiUntouched() {
        let input = [
            det(.contextual, "2025-05-16", customLabel: "date of issue"),
            det(.postalAddress, "123 Main St, Springfield, IL 62704", customLabel: nil),
            det(.organizationName, "Adobe Systems", customLabel: nil),
        ]
        let out = DetectionRelabel.corrected(input)
        XCTAssertEqual(out[0].customLabel, "date of issue")
        XCTAssertEqual(out[1].category, .postalAddress)
        XCTAssertEqual(out[2].category, .organizationName)
    }

    // MARK: defaultKept never auto-checks noise labels (even high-conf / shed-high-risk)
    func test_defaultKept_unchecksNoise() {
        XCTAssertFalse(EditorState.defaultKept(det(.contextual, "x", customLabel: "timestamp", conf: 0.99)))
        XCTAssertFalse(EditorState.defaultKept(det(.contextual, "x", customLabel: "hostname", conf: 0.99)))
        XCTAssertFalse(EditorState.defaultKept(det(.contextual, "x", customLabel: "service name", conf: 0.99)))
        // sanity: a real high-risk detection is still kept
        XCTAssertTrue(EditorState.defaultKept(det(.ssn, "x", customLabel: nil, conf: 0.1)))
    }
}
