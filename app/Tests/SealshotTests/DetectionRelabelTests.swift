import XCTest
import CoreGraphics
@testable import Sealshot

final class DetectionRelabelTests: XCTestCase {
    private func det(_ snippet: String, label: String?) -> Detection {
        Detection(category: .contextual, snippet: snippet, confidence: 0.7, rects: [], customLabel: label)
    }
    func test_containsMeasurementUnit() {
        for s in ["50mg", "50 milligrams", "50 micrograms", "50/ micrograms", "118/78 mmHg", "5 mL", "10 kg"] {
            XCTAssertTrue(DetectionRelabel.containsMeasurementUnit(s), "\(s) should be a measurement")
        }
        for s in ["$5,000", "5,000", "5,000.00", "January 1", ""] {
            XCTAssertFalse(DetectionRelabel.containsMeasurementUnit(s), "\(s) should not be a measurement")
        }
    }
    func test_corrected_relabelsMoneyWithUnit() {
        let out = DetectionRelabel.corrected([det("50 milligrams", label: "money amount")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].customLabel, "measurement")
        XCTAssertEqual(out[0].category, .contextual)
        XCTAssertEqual(out[0].confidence, 0.7)
    }
    func test_corrected_leavesRealMoney() {
        let out = DetectionRelabel.corrected([det("$5,000", label: "money amount")])
        XCTAssertEqual(out[0].customLabel, "money amount")
    }
    func test_corrected_leavesNonMoney() {
        let cc = Detection(category: .creditCard, snippet: "5322 2596 2153 2368", confidence: 0.9, rects: [])
        let org = det("Ashby Medical Center", label: "organization")
        let out = DetectionRelabel.corrected([cc, org])
        XCTAssertEqual(out[0].category, .creditCard)
        XCTAssertEqual(out[1].customLabel, "organization")
    }
}
