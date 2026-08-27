import XCTest
@testable import Sealshot

final class TableReconstructorGuttersTests: XCTestCase {
    private func tok(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 0.08) -> LayoutToken {
        LayoutToken(text: "x", rect: CGRect(x: x, y: y, width: w, height: 0.03))
    }
    func test_splitRegions_widegutter_splitsLeftRight() {
        // left column ~0.05–0.20, right column ~0.60–0.80, gutter 0.20–0.60
        let tokens = [tok(0.05, 0.1), tok(0.05, 0.2), tok(0.62, 0.1), tok(0.62, 0.2)]
        let regions = TableReconstructor.splitRegions(tokens, minGap: 0.15)
        XCTAssertEqual(regions.count, 2)
    }
    func test_splitRegions_singleColumn_oneRegion() {
        let regions = TableReconstructor.splitRegions([tok(0.1, 0.1), tok(0.1, 0.2)], minGap: 0.15)
        XCTAssertEqual(regions.count, 1)
    }
}
