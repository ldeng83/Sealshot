import XCTest
import CoreGraphics
@testable import Sealshot

final class DetectionConsolidationTests: XCTestCase {
    private func det(_ cat: SensitiveCategory, _ snippet: String, _ conf: Double,
                     _ rects: [CGRect], label: String? = nil) -> Detection {
        Detection(category: cat, snippet: snippet, confidence: conf, rects: rects, customLabel: label)
    }

    func test_overlap_dropsFragmentInsideValue() {
        let full = det(.creditCard, "5322 2596 2153 2368", 0.9, [CGRect(x: 0, y: 0, width: 100, height: 20)])
        let frag = det(.contextual, "5322 2596", 0.6, [CGRect(x: 0, y: 0, width: 50, height: 20)], label: "Account number")
        let out = DetectionConsolidation.overlapResolved([frag, full])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.category, .creditCard)
    }
    func test_overlap_keepsNonOverlapping() {
        let a = det(.organizationName, "A", 0.5, [CGRect(x: 0, y: 0, width: 10, height: 10)])
        let b = det(.organizationName, "B", 0.5, [CGRect(x: 100, y: 100, width: 10, height: 10)])
        XCTAssertEqual(DetectionConsolidation.overlapResolved([a, b]).count, 2)
    }
    func test_overlap_sameBboxKeepsHigherConfidence() {
        let r = [CGRect(x: 0, y: 0, width: 40, height: 12)]
        let lo = det(.email, "x@y.com", 0.4, r)
        let hi = det(.email, "x@y.com", 0.9, r)
        let out = DetectionConsolidation.overlapResolved([lo, hi])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.confidence, 0.9)
    }
    func test_overlap_emptyRectsKept() {
        let e = det(.personName, "Nobody", 0.9, [])
        XCTAssertEqual(DetectionConsolidation.overlapResolved([e]).count, 1)
    }

    func test_group_mergesSameValueAcrossLocations() {
        let rects = [CGRect(x: 0, y: 0, width: 30, height: 10),
                     CGRect(x: 0, y: 50, width: 30, height: 10),
                     CGRect(x: 0, y: 100, width: 30, height: 10),
                     CGRect(x: 0, y: 150, width: 30, height: 10)]
        let dets = rects.map { det(.organizationName, "Ashby Medical Center", 0.9, [$0]) }
        let out = DetectionConsolidation.valueGrouped(dets)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.rects.count, 4)
    }
    func test_group_normalizesCaseAndWhitespace() {
        let a = det(.contextual, "Ashby Medical Center", 0.7, [CGRect(x: 0, y: 0, width: 10, height: 10)])
        let b = det(.contextual, "ashby medical center ", 0.7, [CGRect(x: 0, y: 50, width: 10, height: 10)])
        let c = det(.contextual, "Ashby  Medical\nCenter", 0.7, [CGRect(x: 0, y: 100, width: 10, height: 10)])
        XCTAssertEqual(DetectionConsolidation.valueGrouped([a, b, c]).count, 1)
    }
    func test_group_keepsDistinctValues() {
        let a = det(.personName, "Alice", 0.9, [CGRect(x: 0, y: 0, width: 10, height: 10)])
        let b = det(.personName, "Bob", 0.9, [CGRect(x: 0, y: 50, width: 10, height: 10)])
        XCTAssertEqual(DetectionConsolidation.valueGrouped([a, b]).count, 2)
    }
    func test_overlap_keepsDisjointInsideSpreadBbox() {
        // Keeper's two far-apart rects make a tall bbox; a disjoint candidate sits
        // in the gap (inside the bbox) but does NOT overlap the keeper's rects → KEPT.
        let keeper = det(.creditCard, "5322 2596 2153 2368", 0.95,
                         [CGRect(x: 0, y: 0, width: 100, height: 10),
                          CGRect(x: 0, y: 200, width: 100, height: 10)])
        let other = det(.contextual, "OTTAWA", 0.8, [CGRect(x: 0, y: 100, width: 60, height: 10)])
        XCTAssertEqual(DetectionConsolidation.overlapResolved([keeper, other]).count, 2)
    }
    func test_overlap_keepsGeometricallyCoveredButDifferentText() {
        // Same pixels, different value → NOT a fragment → KEPT (substring guard).
        let keeper = det(.personName, "Hello", 0.9, [CGRect(x: 0, y: 0, width: 100, height: 10)])
        let other = det(.personName, "World", 0.8, [CGRect(x: 0, y: 0, width: 70, height: 10)])
        XCTAssertEqual(DetectionConsolidation.overlapResolved([keeper, other]).count, 2)
    }

    func test_consolidate_endToEnd() {
        // full card + fragment (overlap) at one spot, and a duplicated org at two spots.
        let card = det(.creditCard, "5322 2596 2153 2368", 0.9, [CGRect(x: 0, y: 0, width: 100, height: 20)])
        let frag = det(.contextual, "5322 2596", 0.6, [CGRect(x: 0, y: 0, width: 50, height: 20)], label: "Account number")
        let org1 = det(.organizationName, "Ashby Medical Center", 0.9, [CGRect(x: 0, y: 100, width: 30, height: 10)])
        let org2 = det(.organizationName, "Ashby Medical Center", 0.8, [CGRect(x: 0, y: 200, width: 30, height: 10)])
        let out = DetectionConsolidation.consolidate([frag, card, org1, org2])
        XCTAssertEqual(out.count, 2) // one card row, one org row
        XCTAssertEqual(out.first(where: { $0.category == .organizationName })?.rects.count, 2)
        XCTAssertNil(out.first(where: { $0.snippet == "5322 2596" })) // fragment gone
    }
}
