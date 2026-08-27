import XCTest
import CoreGraphics
@testable import Sealshot

final class DetectionContainmentTests: XCTestCase {
    private func det(_ snippet: String, _ rects: [CGRect], _ conf: Double = 0.9) -> Detection {
        Detection(category: .creditCard, snippet: snippet, confidence: conf, rects: rects, customLabel: nil)
    }

    func test_dropsItemFullyInsideLarger() {
        let full = det("5322 2596 2153 2368", [
            CGRect(x: 0, y: 0, width: 40, height: 10), CGRect(x: 50, y: 0, width: 40, height: 10),
            CGRect(x: 100, y: 0, width: 40, height: 10), CGRect(x: 150, y: 0, width: 40, height: 10),
        ])
        let frag = det("5322", [CGRect(x: 0, y: 0, width: 40, height: 10)])   // == the first group
        let out = DetectionConsolidation.containmentResolved([full, frag])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.snippet, "5322 2596 2153 2368")             // the larger survives
    }

    func test_dropsWideRectItemCoveredByPreciseGroupedItem() {
        // The real card case: GLiNER's item has WIDE rects (each spanning two 4-digit
        // groups) and covers fewer groups; the grouped detector's item has precise
        // per-group rects across BOTH cards (larger total). The wide GLiNER item is
        // fully covered by the grouped one → it must drop (single-best coverage would
        // wrongly keep it — this is the bug the union coverage fixes).
        let grouped = det("5322 2596 2153 2368", [
            CGRect(x: 0, y: 0, width: 67, height: 28), CGRect(x: 74, y: 0, width: 67, height: 28),
            CGRect(x: 148, y: 0, width: 67, height: 28), CGRect(x: 222, y: 0, width: 67, height: 28),
            CGRect(x: 0, y: 300, width: 67, height: 28), CGRect(x: 74, y: 300, width: 67, height: 28),
            CGRect(x: 148, y: 300, width: 67, height: 28), CGRect(x: 222, y: 300, width: 67, height: 28),
        ], 0.9)                                             // 8 rects, larger area
        let gliner = det("5322 2596 2153 2368", [
            CGRect(x: 0, y: 0, width: 141, height: 28), CGRect(x: 148, y: 0, width: 141, height: 28),
            CGRect(x: 74, y: 300, width: 67, height: 28), CGRect(x: 148, y: 300, width: 67, height: 28),
        ], 0.69)                                            // wide rects, fewer groups
        let out = DetectionConsolidation.containmentResolved([grouped, gliner])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.rects.count, 8)           // the precise grouped item survives
    }

    func test_keepsDisjointItems() {
        let a = det("1111", [CGRect(x: 0, y: 0, width: 40, height: 10)])
        let b = det("2222", [CGRect(x: 200, y: 0, width: 40, height: 10)])   // no overlap
        XCTAssertEqual(DetectionConsolidation.containmentResolved([a, b]).count, 2)
    }

    func test_keepsPartiallyOverlappingUniqueCoverage() {
        // A spans two cards (top + bottom); B covers only the bottom — B is NOT
        // fully inside A (B has a region A lacks) → both kept (the passport-bug guard).
        let a = det("X", [CGRect(x: 0, y: 0, width: 40, height: 10)])
        let b = det("X Y", [CGRect(x: 0, y: 0, width: 40, height: 10), CGRect(x: 0, y: 500, width: 40, height: 10)])
        // a (smaller) is fully inside b (larger) → a dropped; b kept.
        let out = DetectionConsolidation.containmentResolved([a, b])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.snippet, "X Y")
    }
}
