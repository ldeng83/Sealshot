import XCTest
import CoreGraphics
@testable import Sealshot

final class ShadowPositionTests: XCTestCase {
    func testPadCenterIsZero() {
        XCTAssertEqual(shadowPadOffset(point: CGPoint(x: 64, y: 64), size: 128, maxOffset: 40), CGSize(width: 0, height: 0))
    }
    func testPadRightEdgeIsMaxX() {
        XCTAssertEqual(shadowPadOffset(point: CGPoint(x: 128, y: 64), size: 128, maxOffset: 40), CGSize(width: 40, height: 0))
    }
    func testPadBottomEdgeIsMaxYDown() {
        XCTAssertEqual(shadowPadOffset(point: CGPoint(x: 64, y: 128), size: 128, maxOffset: 40), CGSize(width: 0, height: 40))
    }
    func testPadClampsBeyondEdge() {
        XCTAssertEqual(shadowPadOffset(point: CGPoint(x: 999, y: -999), size: 128, maxOffset: 40), CGSize(width: 40, height: -40))
    }
    func testDirectionCenterResetsToZero() {
        XCTAssertEqual(shadowDirectionSnap(current: CGSize(width: 5, height: 5), dx: 0, dy: 0, fallbackDistance: 14), CGSize(width: 0, height: 0))
    }
    func testDirectionFromCenterUsesFallbackDistance() {
        XCTAssertEqual(shadowDirectionSnap(current: .zero, dx: 1, dy: 0, fallbackDistance: 14), CGSize(width: 14, height: 0))
    }
    func testDirectionPreservesCurrentDistance() {
        XCTAssertEqual(shadowDirectionSnap(current: CGSize(width: 10, height: 0), dx: 0, dy: 1, fallbackDistance: 14), CGSize(width: 0, height: 10))
    }
}
