import XCTest
import CoreGraphics
@testable import Sealshot

/// `scalePenPoints` maps a freehand pen path from its old bounding box into a
/// new one — the box-handle resize for the pen tool (mirroring rectangle /
/// ellipse resize).
final class ScalePenPointsTests: XCTestCase {

    private func assertClose(_ a: [CGPoint], _ b: [CGPoint], _ acc: CGFloat = 1e-6) {
        XCTAssertEqual(a.count, b.count)
        for (p, q) in zip(a, b) {
            XCTAssertEqual(p.x, q.x, accuracy: acc)
            XCTAssertEqual(p.y, q.y, accuracy: acc)
        }
    }

    func test_identityBox_leavesPointsUnchanged() {
        let pts = [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 30)]
        let box = CGRect(x: 10, y: 10, width: 10, height: 20)
        assertClose(scalePenPoints(pts, from: box, to: box), pts)
    }

    func test_doubledBox_scalesPointsProportionally() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        let old = CGRect(x: 0, y: 0, width: 10, height: 10)
        let new = CGRect(x: 0, y: 0, width: 20, height: 20)
        assertClose(scalePenPoints(pts, from: old, to: new),
                    [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 20)])
    }

    func test_midpointMapsToNewMidpoint() {
        let pts = [CGPoint(x: 5, y: 5)]   // center of old
        let old = CGRect(x: 0, y: 0, width: 10, height: 10)
        let new = CGRect(x: 100, y: 200, width: 40, height: 80)
        assertClose(scalePenPoints(pts, from: old, to: new),
                    [CGPoint(x: 120, y: 240)])   // center of new
    }

    func test_degenerateOldBox_returnsPointsUnchanged() {
        let pts = [CGPoint(x: 3, y: 3), CGPoint(x: 3, y: 9)]
        let old = CGRect(x: 3, y: 3, width: 0, height: 6)   // zero width
        let new = CGRect(x: 0, y: 0, width: 10, height: 10)
        assertClose(scalePenPoints(pts, from: old, to: new), pts)
    }
}
