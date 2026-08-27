import XCTest
import CoreGraphics
@testable import Sealshot

/// Pure geometry behind the shared line/arrow renderer: dash patterns and the
/// per-end cap shapes. Drawing itself is visual, but these inputs are exact.
final class ConnectorRenderingTests: XCTestCase {

    // MARK: - dashPattern

    func test_dashPattern_solidIsNil() {
        XCTAssertNil(dashPattern(.solid, width: 4))
    }

    func test_dashPattern_scalesWithStrokeWidth() {
        XCTAssertEqual(dashPattern(.dashed, width: 4) ?? [], [12, 12])
        XCTAssertEqual(dashPattern(.dotted, width: 4) ?? [], [4, 8])
        XCTAssertEqual(dashPattern(.sparseDotted, width: 4) ?? [], [4, 20])
    }

    // MARK: - capGeometry  (direction points outward, toward the tip)

    private let tip = CGPoint(x: 100, y: 50)
    private let right = CGVector(dx: 1, dy: 0)   // pointing +x; perpendicular is (0, 1)

    func test_cap_none_isNone() {
        XCTAssertEqual(capGeometry(.none, tip: tip, direction: right, width: 4), .none)
    }

    func test_cap_filled_isTriangleApexAtTip() {
        // headLen = max(14, 4*2.6)=14, halfW = max(7, 4*1.7)=7.
        XCTAssertEqual(
            capGeometry(.filled, tip: tip, direction: right, width: 4),
            .filledTriangle([CGPoint(x: 100, y: 50),   // apex at tip
                             CGPoint(x: 86, y: 57),    // base corner +perp
                             CGPoint(x: 86, y: 43)])   // base corner -perp
        )
    }

    func test_cap_open_isVBarbsFromTip() {
        XCTAssertEqual(
            capGeometry(.open, tip: tip, direction: right, width: 4),
            .openBarbs(apex: CGPoint(x: 100, y: 50),
                       left: CGPoint(x: 86, y: 57),
                       right: CGPoint(x: 86, y: 43))
        )
    }

    func test_cap_dot_isDiscAtTip() {
        // dotRadius = max(4, 4*1.5) = 6.
        XCTAssertEqual(
            capGeometry(.dot, tip: tip, direction: right, width: 4),
            .dot(center: CGPoint(x: 100, y: 50), radius: 6)
        )
    }

    func test_cap_bar_isPerpendicularSegmentAtTip() {
        // half-length = halfW = 7, perpendicular to the shaft direction.
        XCTAssertEqual(
            capGeometry(.bar, tip: tip, direction: right, width: 4),
            .bar(CGPoint(x: 100, y: 57), CGPoint(x: 100, y: 43))
        )
    }

    // MARK: - outsetTriangle  (uniform border around a filled arrowhead)

    private func triangleContains(_ tri: [CGPoint], _ p: CGPoint) -> Bool {
        guard tri.count == 3 else { return false }
        func sign(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y)
        }
        let d1 = sign(p, tri[0], tri[1])
        let d2 = sign(p, tri[1], tri[2])
        let d3 = sign(p, tri[2], tri[0])
        return !(d1 < 0 || d2 < 0 || d3 < 0) || !(d1 > 0 || d2 > 0 || d3 > 0)
    }

    private func triangleArea(_ tri: [CGPoint]) -> CGFloat {
        guard tri.count == 3 else { return 0 }
        return abs((tri[0].x * (tri[1].y - tri[2].y)
                  + tri[1].x * (tri[2].y - tri[0].y)
                  + tri[2].x * (tri[0].y - tri[1].y)) / 2)
    }

    func test_outset_zeroWidth_isIdentity() {
        let tri = [CGPoint(x: 100, y: 50), CGPoint(x: 86, y: 57), CGPoint(x: 86, y: 43)]
        XCTAssertEqual(outsetTriangle(tri, by: 0), tri)
    }

    func test_outset_enclosesOriginalWithParallelUniformEdges() {
        let tri = [CGPoint(x: 100, y: 50), CGPoint(x: 86, y: 57), CGPoint(x: 86, y: 43)]
        let o = outsetTriangle(tri, by: 3)
        XCTAssertEqual(o.count, 3)
        // Every original vertex lands inside the outset triangle…
        for v in tri {
            XCTAssertTrue(triangleContains(o, v), "vertex \(v) not inside outset \(o)")
        }
        // …each outset edge stays parallel to its original edge (the outline is
        // an outward offset, not a scaled copy)…
        for i in 0..<3 {
            let j = (i + 1) % 3
            let cross = (tri[j].x - tri[i].x) * (o[j].y - o[i].y)
                      - (tri[j].y - tri[i].y) * (o[j].x - o[i].x)
            XCTAssertLessThan(abs(cross), 0.5, "edge \(i) not parallel to original")
        }
        // …and the border grew outward.
        XCTAssertGreaterThan(triangleArea(o), triangleArea(tri))
    }
}
