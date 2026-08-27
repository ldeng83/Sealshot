import XCTest
@testable import Sealshot

final class TableReconstructorRowsTests: XCTestCase {
    private func tok(_ t: String, _ x: CGFloat, _ y: CGFloat) -> LayoutToken {
        LayoutToken(text: t, rect: CGRect(x: x, y: y, width: 0.1, height: 0.04))
    }
    func test_clusterRows_groupsByVerticalCenter_ordersLeftToRight() {
        let tokens = [tok("B", 0.5, 0.10), tok("A", 0.1, 0.105), tok("C", 0.1, 0.30)]
        let rows = TableReconstructor.clusterRows(tokens, tolerance: 0.03)
        XCTAssertEqual(rows.map { $0.map(\.text) }, [["A", "B"], ["C"]])
    }
    func test_clusterRows_separateRowsBeyondTolerance() {
        let rows = TableReconstructor.clusterRows([tok("A", 0.1, 0.10), tok("B", 0.1, 0.20)], tolerance: 0.03)
        XCTAssertEqual(rows.count, 2)
    }
}
