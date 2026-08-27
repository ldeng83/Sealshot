import XCTest
import CoreGraphics
@testable import Sealshot

final class TableReconstructorInBoxesTests: XCTestCase {

    private func tok(_ s: String, _ x: CGFloat, _ y: CGFloat) -> LayoutToken {
        LayoutToken(text: s, rect: CGRect(x: x - 0.01, y: y - 0.005, width: 0.02, height: 0.01))
    }

    // Two side-by-side detected boxes → two independent tables.
    func test_buildInBoxes_twoBoxes_twoTables() {
        let tokens = [
            // left table (x ~0.1..0.3)
            tok("A", 0.12, 0.10), tok("B", 0.28, 0.10),
            tok("1", 0.12, 0.20), tok("2", 0.28, 0.20),
            // right table (x ~0.6..0.8)
            tok("C", 0.62, 0.10), tok("D", 0.78, 0.10),
            tok("3", 0.62, 0.20), tok("4", 0.78, 0.20),
        ]
        let boxes = [CGRect(x: 0.05, y: 0.05, width: 0.35, height: 0.25),
                     CGRect(x: 0.55, y: 0.05, width: 0.35, height: 0.25)]
        let tables = TableReconstructor.buildTables(
            inBoxes: boxes, tokens: tokens,
            tolerance: 0.02, columnSeparation: 0.04, inset: 0.01)
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(tables[0].headers, ["A", "B"])
        XCTAssertEqual(tables[0].rows, [["1", "2"]])
        XCTAssertEqual(tables[1].headers, ["C", "D"])
    }

    // Tokens outside every box are ignored.
    func test_buildInBoxes_excludesTokensOutsideBox() {
        let tokens = [
            tok("A", 0.12, 0.10), tok("B", 0.28, 0.10),
            tok("1", 0.12, 0.20), tok("2", 0.28, 0.20),
            tok("OUT", 0.95, 0.95),
        ]
        let boxes = [CGRect(x: 0.05, y: 0.05, width: 0.35, height: 0.25)]
        let tables = TableReconstructor.buildTables(
            inBoxes: boxes, tokens: tokens,
            tolerance: 0.02, columnSeparation: 0.04, inset: 0.01)
        XCTAssertEqual(tables.count, 1)
        XCTAssertFalse(tables[0].rows.flatMap { $0 }.contains("OUT"))
    }

    // A box that yields a single column (prose) is dropped.
    func test_buildInBoxes_singleColumnDropped() {
        let tokens = [tok("only", 0.20, 0.10), tok("one", 0.20, 0.20)]
        let boxes = [CGRect(x: 0.05, y: 0.05, width: 0.35, height: 0.25)]
        let tables = TableReconstructor.buildTables(
            inBoxes: boxes, tokens: tokens,
            tolerance: 0.02, columnSeparation: 0.04, inset: 0.01)
        XCTAssertTrue(tables.isEmpty)
    }
}
