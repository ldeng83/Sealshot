import XCTest
@testable import Sealshot

final class ImageAutoArrangerTests: XCTestCase {

    private func overlaps(_ rects: [CGRect]) -> Bool {
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let a = rects[i].insetBy(dx: 0.5, dy: 0.5)   // tolerate touching edges
                if a.intersects(rects[j].insetBy(dx: 0.5, dy: 0.5)) { return true }
            }
        }
        return false
    }
    private func box(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }

    func testIndexAlignedAndNoScaling() {
        let sizes = [CGSize(width: 400, height: 300), CGSize(width: 100, height: 200),
                     CGSize(width: 250, height: 250)]
        let rects = ImageAutoArranger.arrange(sizes: sizes, order: .largestFirst, gap: 10)
        XCTAssertEqual(rects.count, 3)
        for (i, s) in sizes.enumerated() {
            XCTAssertEqual(rects[i].size, s, "size preserved (no scaling) at index \(i)")
        }
    }

    func testNoOverlapAndNormalizedToOrigin() {
        let sizes = (0..<12).map { CGSize(width: 100 + CGFloat($0 % 4) * 60,
                                          height: 80 + CGFloat($0 % 3) * 50) }
        for order in [ArrangeOrder.auto, .largestFirst, .smallestFirst] {
            let rects = ImageAutoArranger.arrange(sizes: sizes, order: order, gap: 12)
            XCTAssertFalse(overlaps(rects), "no overlap for \(order)")
            let b = box(rects)
            XCTAssertEqual(b.minX, 0, accuracy: 0.001, "normalized x")
            XCTAssertEqual(b.minY, 0, accuracy: 0.001, "normalized y")
        }
    }

    func testRoughlySixteenByNine() {
        // 16 uniform tiles → a 4x4-ish block should land near 16:9.
        let sizes = Array(repeating: CGSize(width: 160, height: 90), count: 16)
        let rects = ImageAutoArranger.arrange(sizes: sizes, order: .auto, gap: 8)
        let b = box(rects)
        let aspect = b.width / b.height
        XCTAssert(aspect > 1.2 && aspect < 2.6, "aspect \(aspect) roughly 16:9")
    }

    func testAutoBeatsADeliberatelyBadOrder() {
        // Very tall + very wide mixed; auto should get closer to 16:9 than the
        // worst fixed ordering here (smallestFirst tends to stack poorly).
        let sizes = [CGSize(width: 600, height: 100), CGSize(width: 90, height: 500),
                     CGSize(width: 300, height: 300), CGSize(width: 120, height: 400),
                     CGSize(width: 500, height: 120)]
        func aspectErr(_ order: ArrangeOrder) -> CGFloat {
            let b = box(ImageAutoArranger.arrange(sizes: sizes, order: order, gap: 10))
            return abs(b.width / b.height - ImageAutoArranger.targetAspect)
        }
        XCTAssertLessThanOrEqual(aspectErr(.auto), aspectErr(.smallestFirst) + 0.0001)
    }

    func testSingleAndEmpty() {
        XCTAssertEqual(ImageAutoArranger.arrange(sizes: [], order: .auto, gap: 10), [])
        let one = ImageAutoArranger.arrange(
            sizes: [CGSize(width: 50, height: 40)], order: .auto, gap: 10)
        XCTAssertEqual(one, [CGRect(x: 0, y: 0, width: 50, height: 40)])
    }
}
